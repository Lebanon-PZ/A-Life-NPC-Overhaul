-- A-Life Talk v2 (mod id ALifeTalk): free-form typed chat with Project A-Life NPCs through a local LLM.
--
-- How it plugs into A-Life (all functions below exist in Project A-Life 1.4.5; nothing in A-Life is edited):
--   * Input: A-Life's own single-player chat box (ALifeTalkInput.lua, Input.onKeyPressed -> Input.say ->
--     Input.deliver("talkSay") -> ProjectALife.Talk.onPlayerText). We wrap ProjectALife.Talk.respond
--     (ALifeTalk.lua), which onPlayerText calls for the addressed NPC. Menu choices (choiceIntent ~= nil),
--     visitors, door talk, combat, hostile NPCs and every intent that A-Life has a real handler for are passed
--     straight through to A-Life unchanged.
--   * Output: ProjectALife.Speech.say (ALifeSpeech.lua) - the same call A-Life uses, so replies show as normal
--     A-Life speech bubbles and in A-Life's NPC chat log.
--   * Context capture: ProjectALife.Speech.say is also wrapped (capture only, the original always runs first)
--     to remember the last lines NPCs actually said nearby (banter included).
--   * Relationship: ProjectALife.NpcOpinion (valueOf / payload / adjust / talkRefusal / spreadTo),
--     ProjectALife.TalkSocial (ask / typed / mood / config / rowOf / hours) and ProjectALife.Talk.escalate,
--     which is A-Life's own neutral -> careful -> ModuleCareful.noteShout -> hostile ladder.
--   * Actions the LLM may pick are executed by A-Life: Talk.walkWith (WALK_WITH_ME / WALK_STOP) or the original
--     Talk.respond(..., choiceIntent) so A-Life's choiceHandlers / TalkSupplies run them.
--   * NPC <-> NPC: after an NPC answers you, one nearby NPC (A-Life Talk.listeners, Relations.status/sameSide) may
--     chime in and the first may answer back (max 2 extra lines). ProjectALife.ChatterDirector.finish is wrapped
--     (original runs first) so a finished A-Life banter scene near you can get one live follow-up line.
--   * Chat input: A-Life already routes the in-game chat box (processSayMessage/processShoutMessage, wrapped in
--     ALifeTalkInput.lua Input.wrapChat) or its own chat line (chat key) into Talk.onPlayerText -> Talk.respond.
--     Naming an NPC ("Bob, ...") picks who answers.
-- If anything is missing or errors, everything falls back to A-Life's original behaviour (pcall everywhere).

require "ALifeNPCOverhaul/AA_Side" -- pre-1.0: ALifeHealth / ALifeTick / ALifeSide before anything here (was folder order)
ALifeLLMTalk = ALifeLLMTalk or {}
local M = ALifeLLMTalk
local earlySettings = type(M.settings) == "table" and M.settings or nil -- pre-1.0: shared modules' keys (AA_Side)

M.VERSION = "0.8.11.2" -- bridge protocol version: the bridge warns when older than this. Mod version is in mod.info.
M.REQ_FILE = "alifetalk_request.json"
M.REPLY_FILE = "alifetalk_reply.txt"
M.STATUS_FILE = "alifetalk_status.txt"
M.MODDATA = "ALifeTalkLLM"

M.settings = {
    enabled = true,
    -- A-Life Chat Plus merge: immersive by default - no stat windows, no +N/-N popups, no sidebar buttons.
    -- Turn back on in Zomboid/Lua/alifetalk_settings.txt (immersive=false, opinionPopup=true, sideButtons=true).
    immersive = true,
    opinionPopup = false,
    pairPopup = false,
    sideButtons = false,
    fallbackMs = 20000,     -- 0.9 (Nov 16): was 9000, small local models need longer. No AI answer after this -> A-Life answers with its own lines
    lateReplyMs = 30000,    -- v0.4.2: an AI reply that arrives after that (up to 30 s) is still shown, after A-Life's line
    cleanMarkup = true,     -- 0.5.2.3: strip \color{..} / <RGB:..> / [col=..] markup from every line we show
    reshowDedupe = true,    -- 0.5.2.3: a reshow never stacks a second copy of a line still on screen
    speechOnce = true,      -- 0.5.2.4 [pt249u]: one display per line per NPC (same words within speechOnceMs are dropped)
    speechOnceMs = 8000,
    hookOnce = true,        -- 0.5.2.4: every hook / listener is installed once, even if a second copy of a file loads
    stopReAdders = true,    -- 0.5.2.4: a foreign OnTick listener that re-adds another listener every frame is removed
    guardMs = 7000,         -- v0.4.2: for 7 s after our line, an A-Life line drawn over it gets ours shown again after it
    yieldBusy = true,       -- 0.8.2.1: NPC hurt / downed / fighting (A-Life's Speech.quietReason): A-Life's line wins - ours
                            -- is not forced past A-Life's refusal, not guarded and not drawn again (no bubble tug-of-war)
    offlineAfterSec = 6,    -- bridge heartbeat older than this -> bridge offline -> A-Life answers instantly
    pollTicks = 2,          -- check for the reply every 2 ticks
    fastReplyPoll = true,   -- 0.5.2.5 [pt252u]: while YOUR reply is on its way: check every tick
    replyFirst = true,      -- 0.5.2.5: your line never waits behind an overheard-line / event job (those go after it)
    preemptStock = true,    -- 0.5.2.5: an NPC's own pain / injury line cut off by your line is said as its stock line
    orderRule = true,       -- 0.5.2.5: orders ("shoot to kill bandits") get an on-topic yes / no (bridge rule + retry)
    statusCheckMs = 1500,
    heardKeep = 40,         -- remembered nearby NPC lines (all NPCs)
    heardRadius = 25,       -- tiles around the NPC you talk to
    heardMs = 240000,       -- how far back nearby lines count (real ms)
    heardInPrompt = 8,
    memLines = 6,           -- exchanges remembered per NPC (saved with the game, our own ModData)
    earlierInPrompt = 3,
    matesInPrompt = 5,
    negStreakMs = 600000,   -- rude lines closer than 10 min compound
    maxNegPerLine = 15,
    friendAt = 41,          -- NpcOpinion "Likes you" band
    hatesAt = -71,          -- NpcOpinion "Hates you" band: they walk off
    escalateAt = -5,        -- LLM delta at/below this counts as a real insult/threat -> Talk.escalate
    spreadAt = -8,          -- at/below this the group hears about it (NpcOpinion.spreadTo)
    -- NPCs reacting to each other (one request at a time; player lines always jump the queue)
    chimeChance = 55,       -- % chance another nearby NPC chimes in after an NPC answers you
    backChance = 40,        -- % chance the first NPC answers the one who chimed in
    maxChain = 2,           -- NPC lines after the addressed NPC's answer (so at most 3 NPC lines per line you type)
    chainCooldownMs = 15000,
    chimeTimeoutMs = 8000,
    chimeGapMs = 1600,      -- minimum pause between two NPC lines in a back-and-forth
    chimeReachTiles = 10,   -- the one chiming in must be this close to the NPC who spoke  -- a chime-in that takes longer is simply dropped
    -- v3 ambient NPC-to-NPC talk (no player trigger); also settable in Zomboid/Lua/alifetalk_settings.txt
    ambient = true,
    ambientMinSec = 20,     -- check every 20..40 real seconds (random jitter)
    ambientMaxSec = 40,
    ambientCooldownSec = 120, -- per group (or per NPC without a group)
    ambientReplyChance = 60, -- % the other NPC answers (a third line follows with backChance rules, max 3 lines)
    ambientQuietSec = 20,   -- no ambient talk this soon after you said something
    ambientPairTiles = 8,   -- the two NPCs must be this close to each other
    banterChance = 50,      -- % chance an A-Life banter scene gets one live follow-up line (+ maybe a reply)
    banterCooldownMs = 90000,
    banterPlayerTiles = 15, -- only when you are this close (you are the audience)
    targetLockMs = 30000,   -- right-click "Talk (type in chat)" makes that NPC the addressee for this long
    -- v3.2 hearing ranges (tiles): who can hear a line depends on how loud it is
    talkTiles = 14,         -- normal speech (player or NPC)
    shoutTiles = 32,        -- shouted chat ("!" or the shout key)
    -- pre-1.0 MP (docs/PLAN-MP.md P2): the server builds the AI request, the talking player's own bridge answers
    localGreet = true,      -- Nov 16: a plain hello / how are you is answered by A-Life locally, never waits for the AI (off = AI takes it)
    healNeed = 10,          -- pre-1.0 (Joe Nov 19): Need they gain when you treat their wounds (pills / food / water when down: half; 0 = off)
    downedStill = true,     -- pre-1.0 (Rundown Nov 13): someone lying hurt (A-Life downed / dragged) is never turned on the spot (turning plays the crawl)
    chatterHearTiles = 40,  -- pre-1.0 (Joe Nov 20): NPC chatter (banter, chimes, witness lines) is only asked of the AI when a player is this close (0 = no limit)
    mpAI = true,            -- server: use players' AI bridges (off = A-Life's own lines for everyone)
    mpAIStaleSec = 90,      -- server: a player's "my AI is on/off" older than this counts as off
    mpAIStateSec = 20,      -- client: tell the server whether your AI is on at least this often (and on every change)
}
if earlySettings ~= nil then for k, v in pairs(earlySettings) do if M.settings[k] == nil then M.settings[k] = v end end end
M.fileKeys = M.fileKeys or {}
for _, k in ipairs({ "mpAI", "mpAIStaleSec", "mpAIStateSec", "localGreet", "chatterHearTiles", "downedStill", "healNeed" }) do
    local have = false
    for _, x in ipairs(M.fileKeys) do if x == k then have = true end end
    if not have then M.fileKeys[#M.fileKeys + 1] = k end
end
-- v3.2: other files add prompt context here: function(req, player, listener, now) (pcall-guarded)
M.requestExtras = M.requestExtras or {}
-- v3.2: called after every NPC line A-Life or we speak: function(shell, uid, text, x, y) (pcall-guarded)
M.npcLineHooks = M.npcLineHooks or {}
M.playerWordHooks = M.playerWordHooks or {} -- 0.5.1: instant local reactions to the player's words (pause, leave, names)

-- intents A-Life classifies that we deliberately let the AI handle (A-Life only has canned lines for them,
-- no handler); the AI can still trigger the real action through an "act" below
M.aiTakes = { FOLLOW_ME = true, COME_WITH_ME = true, WAIT_HERE = true, JOIN_REQUEST = true }

-- actions the AI may ask A-Life to perform, with the hint shown to the model
-- v0.3.1: hints say plainly who asks whom ("the person talking to you" = the player). The bridge also checks the
-- player's own words before an action may run, and WALK_* are only offered when they make sense right now.
M.actions = {
    { "WALK_WITH_ME", "the person talking to you literally asks you to come along / follow / walk with them" },
    { "WALK_STOP", "you are walking with them now and they literally ask you to stop following / wait here" },
    { "PARTY_JOIN", "they literally ask you to join their group" },
    { "PARTY_LEAVE", "they literally tell you to leave their group" },
    { "PARTY_TASK_ASK", "you are in their group and they ask you for a job/task" },
    { "PARTY_TASK_DONE", "they tell you a job for the group is done" },
    { "PARTY_STORY", "they ask you to tell a story" },
    { "ASK_TRADE", "they literally ask to trade with you" },
    { "ASK_FOOD", "they literally ask you for food" },
    { "ASK_WATER", "they literally ask you for water" },
    { "ASK_MEDS", "they literally ask you for medicine/bandages" },
    { "ASK_NAME", "they literally ask your name" },
    { "HANDS_UP", "they order you to put your hands up" },
    { "DROP_WEAPON", "they order you to drop your weapon" },
    { "DEMAND_ITEMS", "they demand your stuff (robbery)" },
}
-- tones that only count when the bridge scored the line negative / positive (a small model sometimes tags
-- "how is your day" as THREATEN; without this A-Life's TalkSocial.ask would punish it and Talk.escalate would fire)
M.badTone = { INSULT = true, THREATEN = true, GO_AWAY = true }
-- the player's own words must ask for these before A-Life runs them (lower-case plain substrings). HANDS_UP /
-- DROP_WEAPON / DEMAND_ITEMS are the PLAYER ordering the NPC; when the NPC is the one making threats they are
-- never dispatched (the AI's line is simply spoken).
M.actWords = {
    WALK_WITH_ME = { "follow", "come with", "walk with", "tag along", "come along", "escort", "join me", "lead the way",
        "with me", "let's go", "lets go", "come on" },
    WALK_STOP = { "stop following", "stop walking", "wait here", "stay here", "stay put", "wait for me", "you can go",
        "go on without", "go home", "go away", "get lost", "leave me" },
    HANDS_UP = { "hands up", "put your hands", "hands where", "reach for the sky" },
    DROP_WEAPON = { "drop it", "drop the", "drop your", "drop that", "put it down", "put the gun down",
        "put your weapon down", "put that down", "lower your" },
    DEMAND_ITEMS = { "give me your", "give me all", "give me everything", "hand over", "hand it over", "empty your",
        "this is a robbery", "stick up", "stickup" },
}
function M.actAsked(act, text)
    local words = M.actWords[act]
    if words == nil then return true end
    local low = string.lower(tostring(text or ""))
    for _, w in ipairs(words) do if string.find(low, w, 1, true) then return true end end
    return false
end

-- how the player's line came across -> A-Life social intent (ALifeTalkSocialRows.lua categories)
M.tones = { GREETING = true, FAREWELL = true, THANKS = true, SORRY = true, COMPLIMENT = true,
    I_AM_FRIENDLY = true, OFFER_HELP = true, INSULT = true, THREATEN = true, GO_AWAY = true }
-- A-Life categories where we let A-Life's own social rules (TalkSocial.ask) score the line
M.socialCats = { greet = true, farewell = true, kind = true, offer = true, threat = true }

M.why = {
    INSULT = "You insulted them.", THREATEN = "You threatened them.", GO_AWAY = "You told them to get lost.",
    THANKS = "You were polite to them.", SORRY = "You apologised.", COMPLIMENT = "You were kind to them.",
    I_AM_FRIENDLY = "You were friendly.", OFFER_HELP = "You offered to help.", GREETING = "You were friendly.",
}

M.pending = nil
M.queue = {}
-- v3 player-independent jobs that survive a new player line: { request = fn, finish = fn|nil, fallback = fn|nil }
-- (filled in by ALifeLLMTalk_Gifts.lua / ALifeLLMTalk_Events.lua)
M.eventModes = {}
M.lastChainAt = -1e12
M.lastBanterAt = -1e12
M.lock = nil
M.heard = {}
M.tick = 0
M.counter = 0
M.installed = false
M.metrics = { asked = 0, answered = 0, fallback = 0, native = 0, acts = 0, errors = 0, chimes = 0, quiet = 0,
    banter = 0, dropped = 0, readdressed = 0 }

local function log(msg) print("[ALifeTalkLLM] " .. tostring(msg)) end
M.log = log

local function nowMs()
    local ok, v = pcall(getTimestampMs)
    if ok and type(v) == "number" then return v end
    return M.tick * 16
end
M.nowMs = nowMs

-- 0.5.1.6: EVENT HOOK GUARD + PERF COUNTERS. Every Events.X.Add goes through here.
--  * leak guard: the same function can be added to one event at most M.settings.eventAddMax times (default 2).
--    A leftover file (ALifeTalk_RespawnGuard.lua) added its OnTick listener again EVERY frame - the FPS fell forever.
--  * perf counters (setting perfLog, default off): our own handlers are timed; every 30 s the console gets
--    "[ALifeTalk][Perf] ms/sec per hook" so you can see what costs what. Off = no timing, one table lookup per call.
M.perf = { hooks = {}, order = {}, windowAt = 0, loadOpen = true, refused = 0, refusedLogAt = {} }
M.evAdds = M.evAdds or {} -- 0.5.2.4: kept on a re-run (the event wrappers outlive it)
local function perfClock()
    if type(getTimestampNano) == "function" then
        local ok, v = pcall(getTimestampNano)
        if ok and type(v) == "number" then return v / 1000000 end
    end
    local ok, v = pcall(getTimestampMs)
    if ok and type(v) == "number" then return v end
    return 0
end
M.perfClock = perfClock
function M.perfLabel(event)
    local base = M._perfCur or (M.perf.loadOpen and M._file) or nil
    if base == nil then return nil end
    local n = 1
    local key = tostring(base) .. ":" .. tostring(event)
    while M.perf.hooks[key .. (n > 1 and ("#" .. n) or "")] ~= nil do n = n + 1 end
    return key .. (n > 1 and ("#" .. n) or "")
end
function M.perfWrap(label, f)
    local h = { label = label, ms = 0, calls = 0 }
    M.perf.hooks[label] = h
    M.perf.order[#M.perf.order + 1] = h
    return function(...)
        local prev, prevRun = M._perfCur, M._evRunning
        M._perfCur = label
        M._evRunning = f
        if M.settings.perfLog == true then
            local t0 = perfClock()
            local a, b, c = f(...)
            h.ms = h.ms + (perfClock() - t0)
            h.calls = h.calls + 1
            M._perfCur = prev
            M._evRunning = prevRun
            return a, b, c
        end
        local a, b, c = f(...)
        M._perfCur = prev
        M._evRunning = prevRun
        return a, b, c
    end
end
-- 0.5.2.4: foreign OnTick listeners added after load get a thin "who is running" marker (no timing), so a listener
-- that re-adds another one every frame can be found and stopped at the source (see reAddCheck).
function M.trackWrap(f)
    return function(...)
        local prevRun = M._evRunning
        M._evRunning = f
        local a, b, c = f(...)
        M._evRunning = prevRun
        return a, b, c
    end
end
-- 0.5.2.4 [pt249u]: the user's console (console_triple_1025.txt) refused the same OnTick add 67,554 times - one per
-- frame. Source: the leftover ALifeTalk_RespawnGuard.lua. Its tryInstall() stays on OnTick for good and calls
-- install() -> ALifeTick.add(tick) on EVERY call. Refusing the add kept FPS up but the loop never ended. Now the
-- listener that keeps re-adding (tryInstall) is taken off OnTick after 30 refused re-adds; nothing it already did is undone.
M.reAdds = M.reAdds or {}
function M.reAddCheck(ev, name, f)
    if name ~= "OnTick" or M.settings.stopReAdders == false then return false end
    local culprit = M._evRunning
    if culprit == nil or culprit == f then return false end
    local n = (M.reAdds[culprit] or 0) + 1
    M.reAdds[culprit] = n
    if n < 30 then return false end
    M.reAdds[culprit] = nil
    local removed = 0
    local counts = M.evAdds[name] or {}
    for _ = 1, 4 do
        if counts[culprit] == nil and removed > 0 then break end
        local ok = pcall(ev.Remove, culprit)
        if not ok then break end
        removed = removed + 1
    end
    -- what it kept adding (RespawnGuard's tick) got in twice before the refusals began: keep one copy
    for _ = 1, 4 do
        if (counts[f] or 0) <= 1 then break end
        if not pcall(ev.Remove, f) then break end
    end
    M.perf.reAddersStopped = (M.perf.reAddersStopped or 0) + 1
    log("[Perf] stopped the OnTick listener that re-added another listener every frame (" .. tostring(culprit)
        .. " kept adding " .. tostring(f) .. "). That is the leftover ALifeTalk_RespawnGuard.lua (tryInstall) - delete it from"
        .. " mods/ALifeTalk/42/media/lua/client/ALifeLLMTalk/. Setting stopReAdders=false turns this off.")
    return true
end
-- 0.5.2.4: one listener per load. Every file of ours names itself (fileBegin) before it adds listeners; if the same
-- file runs again (a second copy of the add-on, a leftover folder, a Lua reload), its N-th add to an event replaces
-- the N-th add of the earlier run instead of adding a second copy (before: two copies ran every frame).
M.loadAdds = M.loadAdds or {}
M.filePass = M.filePass or {}
M.fileSeq = M.fileSeq or {}
-- the same for our hook lists (requestExtras, npcLineHooks, playerWordHooks): what a file put in them is
-- remembered; when that file runs again, its earlier entries are taken out first (no prompt part / word reaction twice)
M.HOOK_LISTS = { "requestExtras", "npcLineHooks", "playerWordHooks" }
M.fileListAdds = M.fileListAdds or {}
function M.fileClose()
    local file, snap = M._openFile, M._openSnap
    M._openFile, M._openSnap = nil, nil
    if file == nil or type(snap) ~= "table" then return end
    local added = {}
    for _, ln in ipairs(M.HOOK_LISTS) do
        local list, seen = M[ln], snap[ln] or {}
        local mine = {}
        if type(list) == "table" then
            for _, f in ipairs(list) do if not seen[f] then mine[#mine + 1] = f end end
        end
        added[ln] = mine
    end
    M.fileListAdds[file] = added
end
function M.fileOpen(name, again)
    if M.settings.hookOnce == false then return end
    if again then
        local old = M.fileListAdds[name]
        if type(old) == "table" then
            for _, ln in ipairs(M.HOOK_LISTS) do
                local list, drop = M[ln], {}
                for _, f in ipairs(old[ln] or {}) do drop[f] = true end
                if type(list) == "table" then
                    local i = 1
                    while i <= #list do
                        if drop[list[i]] then table.remove(list, i); M.perf.replaced = (M.perf.replaced or 0) + 1 else i = i + 1 end
                    end
                end
            end
        end
    end
    local snap = {}
    for _, ln in ipairs(M.HOOK_LISTS) do
        local seen = {}
        if type(M[ln]) == "table" then for _, f in ipairs(M[ln]) do seen[f] = true end end
        snap[ln] = seen
    end
    M._openFile, M._openSnap = name, snap
end
function M.fileBegin(name)
    name = tostring(name)
    pcall(M.fileClose)
    M._file = name
    M.filePass[name] = (M.filePass[name] or 0) + 1
    M.fileSeq[name] = {}
    M._keying = true
    if M.filePass[name] > 1 then M.reloads = (M.reloads or 0) + 1 end
    pcall(M.fileOpen, name, M.filePass[name] > 1)
end
function M.loadKey(ev, name, f)
    if not M._keying or M.settings.hookOnce == false or M._perfCur ~= nil then return end
    local file = M._file
    if file == nil or M.fileSeq[file] == nil then return end
    local seq = M.fileSeq[file]
    local k = (seq[name] or 0) + 1
    seq[name] = k
    local key = file .. ":" .. name .. "#" .. k
    local pass = M.filePass[file] or 1
    local prev = M.loadAdds[key]
    if prev ~= nil and prev.pass < pass and prev.f ~= nil then
        pcall(ev.Remove, prev.f)
        M.perf.replaced = (M.perf.replaced or 0) + 1
        if not M.replacedLogged then
            M.replacedLogged = true
            log("hooks: " .. file .. ".lua ran again (a second copy of A-Life Talk or a leftover folder?) - its listeners replace the earlier ones, nothing runs twice")
        end
    end
    M.loadAdds[key] = { f = f, pass = pass }
end
function M.perfReport(now)
    if M.settings.perfLog ~= true then M.perf.windowAt = now; return end
    if M.perf.windowAt == 0 then M.perf.windowAt = now; return end
    local sec = (now - M.perf.windowAt) / 1000
    if sec < 30 then return end
    M.perf.windowAt = now
    local rows, total = {}, 0
    for _, h in ipairs(M.perf.order) do
        if h.calls > 0 then rows[#rows + 1] = h; total = total + h.ms end
    end
    table.sort(rows, function(a, b) return a.ms > b.ms end)
    local parts = {}
    for i = 1, math.min(12, #rows) do
        local h = rows[i]
        parts[#parts + 1] = h.label .. "=" .. ALifeFmtDec(h.ms / sec, 2) .. "ms/s(" .. h.calls .. ")"
    end
    print("[ALifeTalk][Perf] " .. ALifeFmtDec(total / sec, 2) .. " ms/sec total over " .. math.floor(sec) .. " s, "
        .. #rows .. " active hooks: " .. table.concat(parts, " ") .. (M.perf.refused > 0 and (" | refused duplicate event adds: " .. M.perf.refused) or ""))
    if M.patch and M.patch() and type(M.patch().perfTake) == "function" then pcall(M.patch().perfTake, sec) end
    for _, h in ipairs(rows) do h.ms = 0; h.calls = 0 end
end
local hookedEvents = { "OnTick", "OnPlayerUpdate", "EveryOneMinute", "EveryTenMinutes", "EveryHours", "EveryDays", "OnGameStart",
    "OnWeaponHitCharacter", "OnHitZombie", "OnWeaponSwing", "OnWorldSound", "OnZombieDead", "OnPlayerDeath", "OnKeyPressed",
    "OnKeyStartPressed", "OnResolutionChange", "OnFillWorldObjectContextMenu", "OnPreUIDraw", "OnPostUIDraw", "OnRenderTick",
    "ProjectALife_NpcDied", "ProjectALife_NpcHit", "ProjectALife_NpcSpawned", "OnCharacterDeath", "OnCreatePlayer" }
function M.hookEventAdds()
    if type(Events) ~= "table" or M.evHooked then return end
    M.evHooked = true
    for _, name in ipairs(hookedEvents) do
        local ev = Events[name]
        if type(ev) == "table" and type(ev.Add) == "function" and ev._alifeTalkHooked ~= true then
            local add, remove = ev.Add, ev.Remove
            local counts, wrapped = {}, {}
            M.evAdds[name] = counts
            ev._alifeTalkHooked = true
            ev.Add = function(f, ...)
                if type(f) ~= "function" then return add(f, ...) end
                local c = counts[f] or 0
                local max = tonumber(M.settings.eventAddMax) or 2
                if M.settings.eventAddGuard ~= false and c >= max then
                    M.perf.refused = M.perf.refused + 1
                    pcall(M.reAddCheck, ev, name, f)
                    local now = nowMs()
                    if now - (M.perf.refusedLogAt[name] or -1e12) >= 60000 then
                        M.perf.refusedLogAt[name] = now
                        log("[Perf] refused to add the same " .. name .. " listener again (already " .. c .. "x; "
                            .. M.perf.refused .. " refused so far) - a mod re-adds it every frame (leftover ALifeTalk_RespawnGuard.lua?)")
                    end
                    return nil
                end
                pcall(M.loadKey, ev, name, f)
                counts[f] = (counts[f] or 0) + 1
                local label = M.perfLabel(name)
                local w = nil
                if label ~= nil then w = M.perfWrap(label, f)
                elseif name == "OnTick" and M.settings.stopReAdders ~= false and M.trackWrap then w = M.trackWrap(f) end
                if w ~= nil then
                    wrapped[f] = wrapped[f] or {}
                    table.insert(wrapped[f], w)
                    return add(w, ...)
                end
                return add(f, ...)
            end
            if type(remove) == "function" then
                ev.Remove = function(f, ...)
                    if type(f) == "function" and counts[f] ~= nil then
                        counts[f] = counts[f] - 1
                        if counts[f] <= 0 then counts[f] = nil end
                        local list = wrapped[f]
                        if type(list) == "table" and #list > 0 then
                            local w = table.remove(list)
                            if #list == 0 then wrapped[f] = nil end
                            return remove(w, ...)
                        end
                    end
                    return remove(f, ...)
                end
            end
        end
    end
end
-- Chat Plus: wrapping EVERY mod's event listeners cost a lot with big mod lists (and made profilers blame this file).
-- Off unless perfHooks=true; the Chat Plus tick governor (ALifeTick) already refuses duplicate adds.
if M.settings.perfHooks == true then M.hookEventAdds() end
M.fileBegin("Main")

local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end
local function round(v) if v >= 0 then return math.floor(v + 0.5) end return -math.floor(-v + 0.5) end
local function roll(n)
    if type(ZombRand) == "function" then
        local ok, v = pcall(ZombRand, n)
        if ok and type(v) == "number" then return v end
    end
    return math.random(0, n - 1)
end
M.roll = roll

local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, name) return type(t) == "table" and type(t[name]) == "function" end

-- v0.4.2: PZ's Kahlua has no next(); 0.4.1 called it in a prompt extra and every request logged an exception
function M.hasAny(t)
    if type(t) ~= "table" then return false end
    for _ in pairs(t) do return true end
    return false
end

-- pre-1.0 MP (P2b): a talk job carries its player; while the job's code runs, "you" (ALifeSide.you) is that player
local function safe(f, ...)
    local job = ...
    local side = ALifeSide
    local set = type(side) == "table" and type(job) == "table" and job.player ~= nil
    local prev = set and side.cur or nil
    if set then side.cur = job.player end
    local ok, a, b, c = pcall(f, ...)
    if set then side.cur = prev end
    if ok then return a, b, c end
    M.metrics.errors = M.metrics.errors + 1
    log("error: " .. tostring(a))
    return nil
end

----------------------------------------------------------------------------------------------------------------
-- JSON (encoder only; Kahlua has no json library)
----------------------------------------------------------------------------------------------------------------
local escMap = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
local function jsonStr(s)
    s = string.gsub(tostring(s), '[%c"\\]', function(c) return escMap[c] or string.format("\\u%04x", string.byte(c)) end)
    return '"' .. s .. '"'
end
local function isArray(t)
    local n = 0
    for k, _ in pairs(t) do
        if type(k) ~= "number" then return false end
        n = n + 1
    end
    return n == #t
end
local function jsonEncode(v, depth)
    depth = depth or 0
    if depth > 6 then return "null" end
    local tv = type(v)
    if tv == "nil" then return "null" end
    if tv == "boolean" then return v and "true" or "false" end
    if tv == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return "0" end
        if math.floor(v) == v then return tostring(math.floor(v)) end
        return ALifeFmtDec(v, 2)
    end
    if tv == "string" then return jsonStr(v) end
    if tv == "table" then
        local parts = {}
        if isArray(v) then
            for i = 1, #v do parts[#parts + 1] = jsonEncode(v[i], depth + 1) end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        for k, val in pairs(v) do parts[#parts + 1] = jsonStr(k) .. ":" .. jsonEncode(val, depth + 1) end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return jsonStr(tostring(v))
end
M.jsonEncode = jsonEncode

----------------------------------------------------------------------------------------------------------------
-- File IO (vanilla getFileWriter / getFileReader, Zomboid/Lua folder)
----------------------------------------------------------------------------------------------------------------
local writeFile, readLines
function writeFile(name, text)
    local ok, err = pcall(function()
        local w = getFileWriter(name, true, false)
        w:write(text)
        w:close()
    end)
    if not ok then log("write failed: " .. tostring(err)) end
    return ok
end

function readLines(name)
    local lines
    pcall(function()
        local r = getFileReader(name, false)
        if not r then return end
        lines = {}
        local line = r:readLine()
        while line ~= nil do
            lines[#lines + 1] = line
            line = r:readLine()
        end
        r:close()
    end)
    return lines
end
M.readLines = readLines
M.writeFile = writeFile
-- pre-1.0 MP: the request goes to the bridge on this machine, or (MP server) to the talking player's machine
function M.aiWrite(job, text, id)
    if type(ALifeSide) == "table" and ALifeSide.mpServer() then
        if M.settings.mpAI == false or type(ALifeAIRelay) ~= "table" then return false end
        return ALifeAIRelay.ask(job, text, id)
    end
    return writeFile(M.REQ_FILE, text)
end
function M.aiRead()
    if type(ALifeSide) == "table" and ALifeSide.mpServer() then
        if type(ALifeAIRelay) ~= "table" then return nil end
        return ALifeAIRelay.lines()
    end
    return readLines(M.REPLY_FILE)
end

M.status = { checkedAt = -1e12, alive = false }
function M.bridgeAlive(now, player)
    now = now or nowMs()
    if type(ALifeSide) == "table" and ALifeSide.mpServer() then
        if M.settings.mpAI == false or type(ALifeAIRelay) ~= "table" then return false end
        return ALifeAIRelay.aiOn(player, now)
    end
    if now - M.status.checkedAt < M.settings.statusCheckMs then return M.status.alive end
    M.status.checkedAt = now
    local alive = false
    local lines = readLines(M.STATUS_FILE)
    if lines and lines[1] then
        local ts = tonumber((string.match(lines[1], "alive%s+(%d+)")))
        local okNow, sec = pcall(getTimestamp)
        if ts and okNow and type(sec) == "number" and sec > 1000000000 then
            alive = math.abs(sec - ts) <= M.settings.offlineAfterSec
        end
        -- 0.5.2.6 [pt254u]: the bridge writes "alive <time> <model> ver=0.5.2.6"; older bridges write no version
        M.status.version = string.match(lines[1], "ver=([%d%.]+)")
    end
    M.status.alive = alive
    if alive and M.bridgeVersionCheck then pcall(M.bridgeVersionCheck, M.status.version) end
    return alive
end

-- 0.5.2.6: "1.2.10" > "1.2.9"; nil (no version reported) counts as older than everything
function M.versionOlder(a, b)
    if a == nil then return true end
    local pa, pb = {}, {}
    for x in string.gmatch(tostring(a), "%d+") do pa[#pa + 1] = tonumber(x) end
    for x in string.gmatch(tostring(b), "%d+") do pb[#pb + 1] = tonumber(x) end
    for i = 1, math.max(#pa, #pb) do
        local x, y = pa[i] or 0, pb[i] or 0
        if x ~= y then return x < y end
    end
    return false
end
-- warn once (console + on screen) when the bridge is older than the mod: new prompt rules (orders, the never-cut
-- DEAD facts, ...) live in the bridge, an old one silently ignores them. Off: bridgeVersionWarn.
function M.bridgeVersionCheck(ver)
    if M.settings.bridgeVersionWarn == false or M.bridgeVersionWarned then return false end
    if not M.versionOlder(ver, M.VERSION) then return false end
    M.bridgeVersionWarned = true
    local msg = "A-Life NPC Overhaul: your AI helper is out of date (bridge " .. tostring(ver or "?") .. ", needs " .. M.VERSION .. ")."
        .. " AI tab > Open the AI folder, then double-click \"Restart AI helper.cmd\"."
    print("[ALifeTalk] WARNING: " .. msg)
    log("bridge version mismatch: bridge " .. tostring(ver or "?") .. " < mod " .. M.VERSION)
    pcall(function()
        local pl = type(ALifeSide) == "table" and ALifeSide.localPlayer() or (type(getPlayer) == "function" and getPlayer() or nil)
        if pl == nil then return end
        local note = "AI helper out of date: run Restart AI helper.cmd"
        -- B42: HaloTextHelper.addText(player, text, ColorRGB) is not always implemented; prefer setHaloNote
        if type(ALifeLetter) == "function" then
            ALifeLetter(pl, msg, 255, 90, 90, true)
        elseif type(pl.setHaloNote) == "function" then
            pl:setHaloNote(note, 255, 90, 90, 600)
        elseif type(HaloTextHelper) == "table" and type(HaloTextHelper.addText) == "function" then
            pcall(HaloTextHelper.addText, pl, note)
        end
    end)
    M.bridgeVersionMsg = msg
    return true
end

----------------------------------------------------------------------------------------------------------------
-- Our own small save data: last exchanges per NPC + compounding streaks (no relationship score; A-Life owns that)
----------------------------------------------------------------------------------------------------------------
-- v3: id of this save for the bridge's memory folder (alifetalk_mem/<worldId>/). Kept in the save's global
-- ModData, so it is stable across restarts and different saves never share NPC memory files.
function M.worldId()
    local data = M.store()
    if type(data) == "table" and type(data.worldId) == "string" and data.worldId ~= "" then return data.worldId end
    if type(data) ~= "table" and M.sessionWorldId ~= nil then return M.sessionWorldId end
    local name = "save"
    pcall(function()
        local w = getWorld():getWorld()
        if type(w) == "string" and w ~= "" then name = w end
    end)
    name = string.gsub(string.sub(name, 1, 40), "[^%w_%-]", "_")
    local stamp = 0
    pcall(function() stamp = math.floor(getTimestamp() % 10000000) end)
    local id = name .. "_" .. tostring(stamp) .. "_" .. tostring(roll(9000) + 1000)
    if type(data) == "table" then data.worldId = id else M.sessionWorldId = id end
    return id
end

-- v0.4.0: engine probes that failed once stay off for the session (keeps console.txt clean)
M.probes = {}
-- v0.4.0: context-menu entries with our icon (themed); plain option if the theme is not loaded
function M.menuOpt(context, icon, label, target, f, ...)
    if M.Theme and M.Theme.menuOption then return M.Theme.menuOption(context, label, target, f, icon, ...) end
    return context:addOption(label, target, f, ...)
end

function M.probeOff(key, set)
    if set then
        if not M.probes[key] then M.probes[key] = true; log("probe '" .. tostring(key) .. "' unavailable in this game version; skipped from now on") end
        return true
    end
    return M.probes[key] == true
end

-- v0.4.0: living A-Life NPCs near a point. Registry + A-Life's own shell binding, with a cell scan as fallback
-- (Talk.listeners leaves out busy / hostile NPCs, which is why fights and deaths had "0 witnesses").
function M.nearbyNpcs(x, y, z, tiles, exceptUid)
    local pa = PA()
    local out, seen = {}, {}
    if x == nil then return out end
    local r2 = tiles * tiles
    local function consider(rec, sh)
        if rec == nil or sh == nil or seen[tostring(rec.uid)] or tostring(rec.uid) == tostring(exceptUid) then return end
        if rec.lifecycle ~= "active" then return end
        local sx, sy, sz = nil, nil, nil
        pcall(function() sx, sy, sz = sh:getX(), sh:getY(), sh:getZ() end)
        if sx == nil or math.abs(math.floor(sz or 0) - math.floor(z or 0)) > 1 then return end
        local dd = (sx - x) ^ 2 + (sy - y) ^ 2
        if dd > r2 then return end
        if fn(pa.Speech, "alive") and pa.Speech.alive(sh) ~= true then return end
        seen[tostring(rec.uid)] = true
        out[#out + 1] = { record = rec, shell = sh, d2 = dd }
    end
    if fn(pa.ActorRegistry, "each") then
        pcall(pa.ActorRegistry.each, function(rec)
            if rec.lifecycle == "active" then
                local sh = nil
                if fn(pa.Talk, "shellFor") then pcall(function() sh = pa.Talk.shellFor(rec.uid) end) end
                local wp = rec.worldPosition
                if sh == nil and fn(pa.Speech, "findShell") and type(wp) == "table" and tonumber(wp.x)
                        and (wp.x - x) ^ 2 + ((tonumber(wp.y) or 0) - y) ^ 2 <= r2 * 4 then
                    pcall(function() sh = pa.Speech.findShell(tostring(rec.uid)) end)
                end
                consider(rec, sh)
            end
            return false
        end)
    end
    if #out == 0 and fn(pa.Speech, "variable") and fn(pa.ActorRegistry, "read") then
        pcall(function()
            local list = getCell():getZombieList()
            for i = 0, math.min(list:size(), 800) - 1 do
                local sh = list:get(i)
                local uid = pa.Speech.variable(sh, "ALifeUID")
                if uid ~= nil and uid ~= "" then consider(pa.ActorRegistry.read(tostring(uid)), sh) end
            end
        end)
    end
    table.sort(out, function(a, b) return a.d2 < b.d2 end)
    return out
end

function M.store()
    local ok, data = pcall(function() return ModData.getOrCreate(M.MODDATA) end)
    if ok and type(data) == "table" then
        data.npcs = type(data.npcs) == "table" and data.npcs or {}
        return data
    end
    M._mem = M._mem or { npcs = {} }
    return M._mem
end

function M.memFor(uid)
    local data = M.store()
    local key = tostring(uid)
    local row = data.npcs[key]
    if type(row) ~= "table" then
        row = { lines = {}, neg = 0, negAt = 0, pos = 0 }
        data.npcs[key] = row
    end
    row.lines = type(row.lines) == "table" and row.lines or {}
    return row
end

----------------------------------------------------------------------------------------------------------------
-- Position helpers
----------------------------------------------------------------------------------------------------------------
local function pos(obj)
    if obj == nil then return nil end
    local ok, x, y, z = pcall(function() return obj:getX(), obj:getY(), obj:getZ() end)
    if ok then return x, y, z end
    return nil
end

local function uidOf(shell)
    if shell == nil then return nil end
    local pa = PA()
    if pa and fn(pa.Speech, "variable") then
        local v = pa.Speech.variable(shell, "ALifeUID")
        if v ~= nil and tostring(v) ~= "" then return tostring(v) end
    end
    return nil
end

M.uidOf = uidOf

----------------------------------------------------------------------------------------------------------------
-- Capture what NPCs actually say (wrapper around ProjectALife.Speech.say; original always runs first)
----------------------------------------------------------------------------------------------------------------
function M.remember(entry)
    local list = M.heard
    list[#list + 1] = entry
    while #list > M.settings.heardKeep do table.remove(list, 1) end
end

function M.noteNpcLine(shell, text)
    if type(text) ~= "string" or text == "" then return end
    M.lastNpcLineAt = nowMs()
    local x, y = pos(shell)
    local uid = uidOf(shell)
    M.remember({ at = nowMs(), uid = uid, text = text, x = x, y = y, r = M.settings.talkTiles })
    for _, f in ipairs(M.npcLineHooks) do pcall(f, shell, uid, text, x, y) end
end

function M.notePlayerLine(player, text)
    M.lastPlayerLineAt = nowMs()
    -- v3.2: the hearing wrapper (Talk.onPlayerText) already stored this line with its loudness
    local h = M.heardPlayerLast
    if h ~= nil and h.text == text and nowMs() - h.at < 2000 then return end
    local x, y = pos(player)
    M.remember({ at = nowMs(), player = true, text = text, x = x, y = y, r = M.settings.talkTiles })
end

----------------------------------------------------------------------------------------------------------------
-- Native-intent test: true = let A-Life answer it exactly as before
----------------------------------------------------------------------------------------------------------------
function M.isNative(intent, state)
    if state ~= nil and state.pending ~= nil then return true end -- A-Life asked a yes/no question; it owns the answer
    if intent == nil then return false end
    if M.aiTakes[intent] then return false end
    local pa = PA()
    local talk = pa.Talk
    if type(talk.choiceHandlers) == "table" and type(talk.choiceHandlers[intent]) == "function" then return true end
    if fn(pa.TalkSupplies, "handles") and pa.TalkSupplies.handles(intent) then return true end
    local rows = pa.TalkSocialRows
    if fn(rows, "category") and rows.category(intent) == "answer" then
        return false -- "yes/ok/no" with no pending A-Life question ("you holding up ok?"): free talk, the AI takes it
    end
    if fn(rows, "exemptIntent") and rows.exemptIntent(intent) then return true end -- system/order rows
    if fn(pa.TalkIntents, "choiceById") then
        local choice = pa.TalkIntents.choiceById(intent)
        if type(choice) == "table" and choice.npcAnswer == true then return true end
    end
    if intent == "NPC_OPEN" then return true end
    return false
end

function M.actAvailable(id)
    local pa = PA()
    if pa == nil or pa.Talk == nil then return false end
    if id == "WALK_WITH_ME" or id == "WALK_STOP" then return fn(pa.Talk, "walkWith") end
    if type(pa.Talk.choiceHandlers) == "table" and type(pa.Talk.choiceHandlers[id]) == "function" then return true end
    if fn(pa.TalkSupplies, "handles") and pa.TalkSupplies.handles(id) then return true end
    return false
end

-- is this NPC walking with this player right now? (A-Life's own walkWith memory, see Talk.walkWith)
function M.walkingWith(listener, player)
    if type(listener) ~= "table" or type(listener.record) ~= "table" or player == nil then return nil end
    local memory = type(listener.record.memory) == "table" and listener.record.memory or {}
    local speech = PA() and PA().Speech
    if not fn(speech, "playerKey") then return nil end
    local ok, key = pcall(speech.playerKey, player)
    if not ok then return nil end
    return type(memory.walkWith) == "table" and memory.walkWith.key == key
end

function M.availableActs(listener, player)
    local list, hints = {}, {}
    local walking = M.walkingWith(listener, player)
    for _, row in ipairs(M.actions) do
        local id = row[1]
        local sensible = not ((id == "WALK_STOP" and walking == false) or (id == "WALK_WITH_ME" and walking == true))
        -- v3.2: never offer WALK_WITH_ME when A-Life's own rules would refuse it (stance, opinion, cooldown)
        if sensible and id == "WALK_WITH_ME" and M.followVerdict then
            local okV, v = pcall(M.followVerdict, listener, player)
            if okV and v ~= nil then sensible = false end
        end
        if sensible and M.actAvailable(id) then
            list[#list + 1] = row[1]
            hints[#hints + 1] = row[1] .. "=" .. row[2]
        end
    end
    return list, hints
end

----------------------------------------------------------------------------------------------------------------
-- The Talk.respond wrapper
----------------------------------------------------------------------------------------------------------------
-- who is being spoken to: an NPC named in the line ("Bob, ...") wins, then a right-click target lock, then A-Life's
-- own pick (Talk.addressee: the nearest NPC in front of you). Only NPCs from A-Life's Talk.listeners (earshot).
local function hasWord(hay, word)
    local start = 1
    while true do
        local i, j = string.find(hay, word, start, true)
        if i == nil then return false end
        local before, after = string.sub(hay, i - 1, i - 1), string.sub(hay, j + 1, j + 1)
        if not string.find(before, "%a") and not string.find(after, "%a") then return true end
        start = j + 1
    end
end

function M.readdress(player, listener, text, now)
    local talk = PA().Talk
    if not fn(talk, "listeners") or type(text) ~= "string" then return listener end
    local radius = type(talk.settings) == "table" and talk.settings.listenRadius or 12
    local list = talk.listeners(player, radius)
    local low = " " .. string.lower(text) .. " "
    for _, l in ipairs(list) do
        local memory = type(l.record) == "table" and type(l.record.memory) == "table" and l.record.memory or {}
        local first = memory.personFirst
        if type(first) == "string" and #first > 1 and hasWord(low, string.lower(first)) then
            if listener == nil or l.record.uid ~= listener.record.uid then M.metrics.readdressed = M.metrics.readdressed + 1 end
            return l
        end
    end
    if M.lock ~= nil and now < M.lock.untilMs then
        for _, l in ipairs(list) do if tostring(l.record.uid) == M.lock.uid then return l end end
    end
    return listener
end

-- Nov17 #1: wrappers of Talk.respond (ours, this load or an earlier copy of this file) are remembered here, so one
-- is never taken for "A-Life's original" (M.origRespond == M.respond made respond -> respondNow -> respond forever)
ALifeLLMTalk._ours = ALifeLLMTalk._ours or {}
function M.realRespond()
    local o = M.origRespond
    if type(o) == "function" and not ALifeLLMTalk._ours[o] then return o end
    local pa = PA()
    local hm = pa and type(pa.Talk) == "table" and rawget(pa.Talk, "_alifeTalkHooks") or nil
    local mark = type(hm) == "table" and hm.respond or nil
    if type(mark) == "table" and type(mark.orig) == "function" and not ALifeLLMTalk._ours[mark.orig] then
        M.origRespond = mark.orig
        return mark.orig
    end
    if not M.loopLogged then M.loopLogged = true; log("WARNING: Talk.respond original not found (our own wrapper was taken for it); AI/native answer skipped, no loop") end
    return nil
end
-- pre-1.0 MP (P2b): A-Life's Talk.respond runs on the server in MP; everything under it asks ALifeSide.you() for
-- "you", which is the player who typed the line while it runs (single player: the one player, as before)
function M.respond(player, listener, text, now, choiceIntent)
    local side = ALifeSide
    if type(side) ~= "table" or player == nil then return M.respondNow(player, listener, text, now, choiceIntent) end
    local prev = side.cur
    side.cur = player
    local ok, a, b, c, d = pcall(M.respondNow, player, listener, text, now, choiceIntent)
    side.cur = prev
    if not ok then error(a, 0) end
    return a, b, c, d
end
ALifeLLMTalk._ours[M.respond] = true
-- a listener's NPC, if it has one (stable across calls; unlike the listener table itself, which A-Life's own
-- talk.listeners() rebuilds fresh every call, so comparing listener == listener by identity never matches twice)
local function listenerUid(l) return type(l) == "table" and type(l.record) == "table" and tostring(l.record.uid) or nil end
function M.respondNow(player, listener, text, now, choiceIntent)
    M.respondHit = true
    if choiceIntent == nil and not M.inNative and M.settings.enabled then
        local okA, picked = pcall(M.readdress, player, listener, text, now or nowMs())
        if okA and picked ~= nil then listener = picked end
    end
    local orig = M.realRespond()
    -- loop breaker: the "original" we call came back into us with the very same line (a wrapper chain that ends in
    -- our own respond: console 41072 / Nov22 Discord, respond -> respondNow -> respond until Stack overflow). Never
    -- call it again. Matched on the NPC's uid (readdress already applied on both sides), not table identity: the
    -- old check compared this call's listener (before readdress) against the outer call's act.listener (after
    -- readdress) -> never equal once readdress actually redirected to a named NPC, so the loop ran unchecked.
    -- respondDepth is a hard backstop beneath that: any reentry at all, for any reason, stops here first.
    M.respondDepth = (M.respondDepth or 0) + 1
    local act = M.origActive
    local uid = listenerUid(listener)
    local looped = M.respondDepth > 4
        or (act ~= nil and act.player == player and act.uid == uid and act.text == text and act.intent == choiceIntent)
    if looped then
        M.respondDepth = M.respondDepth - 1
        if not M.loopLogged then M.loopLogged = true; log("WARNING: Talk.respond loops back into A-Life Talk (another mod's wrapper?); answer skipped, no loop") end
        return nil
    end
    if choiceIntent == nil and not M.inNative and type(listener) == "table" and type(listener.record) == "table" then
        M.lastAddressee = { uid = tostring(listener.record.uid), at = nowMs(), text = text }
    end
    -- 0.8.3 step 4b: a row picked in A-Life's talk window (choiceIntent = the row id, text = its words) goes to the
    -- AI too when it is only talk (no A-Life handler behind it: M.isNative decides, as for typed lines). Off: aiRows.
    local rowToAi = choiceIntent ~= nil and M.settings.aiRows ~= false
    if (choiceIntent == nil or rowToAi) and not M.inNative then
        local ok, deferred, said, reason = pcall(M.tryDefer, player, listener, text, now, choiceIntent)
        if ok and deferred == true then
            if choiceIntent ~= nil then M.metrics.aiRows = (M.metrics.aiRows or 0) + 1 end
            M.respondDepth = M.respondDepth - 1
            return said, reason
        end
        if not ok then
            M.metrics.errors = M.metrics.errors + 1
            log("defer error: " .. tostring(deferred))
        end
    end
    M.metrics.native = M.metrics.native + 1
    if choiceIntent == nil and type(text) == "string" then pcall(M.notePlayerLine, player, text) end -- v3: memory/context
    -- 0.8.3 step 4b: while A-Life answers, Talk.speak may swap its stock line for one about how they really are
    -- (ALifeTalk_StockLines.lua); only inside this call, never for barks elsewhere
    M.inStockRespond = (M.inStockRespond or 0) + 1
    local okO, a, b, c = false, nil, nil, nil
    if orig ~= nil then
        local prevAct = M.origActive
        M.origActive = { player = player, uid = uid, text = text, intent = choiceIntent }
        okO, a, b, c = pcall(orig, player, listener, text, now, choiceIntent)
        M.origActive = prevAct
    else okO = true end
    M.inStockRespond = M.inStockRespond - 1
    M.respondDepth = M.respondDepth - 1
    if not okO then error(a, 0) end
    return a, b, c
end

-- v0.4.2: another mod (re)assigned ProjectALife.Talk.respond with a function that no longer reaches ours, so A-Life
-- answered every line itself. Noticed per player line (the onPlayerText wrapper); ours is put back on top of
-- whatever is there now (that function stays the original we call), once per session at most 3 times.
M.rewraps = 0
function M.respondBypassed(reason)
    local pa = PA()
    if pa == nil or pa.Talk == nil or pa.Talk.respond == M.respond or M.rewraps >= 3 then return false end
    if M.isOurHook(pa.Talk, "respond") then return false end -- 0.5.2.4: an earlier copy's wrapper is still ours
    M.rewraps = M.rewraps + 1
    M.origRespond = pa.Talk.respond
    pa.Talk.respond = M.respond
    M.hookMark(pa.Talk).respond = { orig = M.origRespond, wrapper = M.respond, version = M.VERSION }
    log("WARNING: another mod replaced ProjectALife.Talk.respond without calling A-Life Talk (answer reason "
        .. tostring(reason) .. "); A-Life Talk is wrapped around it again, so AI replies work from your next line")
    return true
end

function M.isSP()
    local client = ALifeSide.client()
    local server = ALifeSide.server()
    return not client and not server
end
-- pre-1.0 MP (P2b): world logic may run here (single player or the MP server; never an MP client). Ported modules
-- ask this instead of isSP(). "You" in world logic: M.you(p) / M.players() / M.eachPlayer(f) (ALifeSide P2b).
function M.worldHere()
    if type(ALifeSide) == "table" then return ALifeSide.world() end
    return M.isSP()
end
function M.you(p)
    if type(ALifeSide) == "table" then return ALifeSide.you(p) end
    if p ~= nil then return p end
    return type(getPlayer) == "function" and getPlayer() or nil
end
function M.players()
    if type(ALifeSide) == "table" then return ALifeSide.online() end
    local p = M.you()
    return p ~= nil and { p } or {}
end
function M.eachPlayer(f, ...)
    if type(ALifeSide) == "table" then return ALifeSide.each(f, ...) end
    local p = M.you()
    if p ~= nil then pcall(f, p, ...); return 1 end
    return 0
end
-- pre-1.0 MP (P4): a CHOICE CARD from world logic. Single player: the moment card window (M.momCard, a client file;
-- canOutCard() = it exists, exactly the old check). MP server: ALifeOut.card to that player (the server keeps the
-- choices; the player's pick runs them there; nil player = nobody: the card is not shown).
function M.mpServerHere() return type(ALifeSide) == "table" and ALifeSide.mpServer() end
-- (the helpers live on ALifeSide since P5 so stubbed test tables work too; these are the same functions)
function M.canOutCard() return ALifeSide.canOutCard() end
function M.outCard(player, card) return ALifeSide.outCard(player, card) end
-- pre-1.0 MP (P5): THE SCREEN FROM WORLD LOGIC, in one call each. Single player: exactly the old direct call
-- (M.momToast / M.momNote / ALifeLetter / the journal map). MP server: ALifeOut to that player (nil = the player
-- being handled, ALifeSide.cur; a nil player with no one handled = everyone online).
function M.outToast(player, text, r, g, b) return ALifeSide.outToast(player, text, r, g, b) end
function M.outNote(player, text, r, g, b) return ALifeSide.outNote(player, text, r, g, b) end
function M.outLetter(player, text, r, g, b, bad) return ALifeSide.outLetter(player, text, r, g, b, bad) end
-- news is world data (the bulletins' pool, News.lua), kept where the world is: the same call on every side
function M.outNews(cat, text, x, y)
    if type(M.newsNote) == "function" then return M.newsNote(cat, text, x, y) end
end
-- pre-1.0 MP (P5): PER-PLAYER FIELDS on M, MP server only. After M.perPlayer("radio"), M.radio reads / writes the slot
-- of the player being handled (ALifeSide.cur; nobody handled = nil, writes dropped). Single player / MP client: a
-- plain field, nothing changes. M.perPlayerAll(name) = { [player key] = value } (for loops / tests).
M._ppFields = M._ppFields or {}
M._ppData = M._ppData or {}
function M.perPlayer(name)
    if not M.mpServerHere() or M._ppFields[name] then return false end
    M._ppFields[name] = true
    M._ppData[name] = M._ppData[name] or {}
    rawset(M, name, nil)
    if getmetatable(M) == nil then
        setmetatable(M, {
            __index = function(t, k)
                if not M._ppFields[k] then return nil end
                local p = ALifeSide.cur
                if p == nil then return nil end
                return M._ppData[k][ALifeSide.keyOf(p)]
            end,
            __newindex = function(t, k, v)
                if not M._ppFields[k] then rawset(t, k, v); return end
                local p = ALifeSide.cur
                if p ~= nil then M._ppData[k][ALifeSide.keyOf(p)] = v end
            end,
        })
    end
    return true
end
function M.perPlayerAll(name) return M._ppData[name] or {} end
-- a mark on the player's paper map (the journal's queue). MP: sent to that player's machine, drawn there.
function M.outMark(player, text, x, y) return ALifeSide.outMark(player, text, x, y) end
-- pre-1.0 MP (P4): THE PLAYER WHOSE BASE THIS IS. Co-op: one shared camp / base / settlers. Single player: you.
-- MP server: the player being handled (a per-player loop, a talk, a window call) when they have a base, else the
-- online player with an A-Life base nearest (x, y) (any of them when no spot is given), else the player being handled,
-- else the online player nearest (x, y), else anyone. Bases are looked up at most every 2 s per player.
M._hpBase = M._hpBase or {}
local function hasBase(p, now)
    local c = M._hpBase[p]
    if c == nil or now - c.at > 2000 or now < c.at then
        local ok, b = pcall(function() return type(M.alifeBase) == "function" and M.alifeBase(p) or nil end)
        c = { at = now, has = ok and b ~= nil }
        M._hpBase[p] = c
    end
    return c.has
end
function M.homePlayer(x, y)
    if type(ALifeSide) ~= "table" or not ALifeSide.mpServer() then return M.you() end
    local now = M.nowMs and M.nowMs() or 0
    local cur = ALifeSide.cur
    if cur ~= nil and hasBase(cur, now) then return cur end
    local best, bd, any = nil, nil, nil
    x, y = tonumber(x), tonumber(y)
    for _, p in ipairs(ALifeSide.online()) do
        any = any or p
        if hasBase(p, now) then
            local d = 0
            if x ~= nil then
                local px, py = nil, nil
                pcall(function() px, py = p:getX(), p:getY() end)
                d = px ~= nil and ((px - x) ^ 2 + (py - y) ^ 2) or 1e12
            end
            if bd == nil or d < bd then best, bd = p, d end
        end
    end
    if best ~= nil then return best end
    if cur ~= nil then return cur end
    if x ~= nil then local n = ALifeSide.nearest(x, y); if n ~= nil then return n end end
    return any
end
-- pre-1.0 MP: AI talk can start here: single player, or the MP server (players' bridges). Never an MP client.
function M.aiHere()
    if M.isSP() then return true end
    if type(ALifeSide) == "table" and ALifeSide.mpServer() then return M.settings.mpAI ~= false end
    return false
end

-- 0.8.11.2 (Lava / Kingston): one console line per typed line - who answers it and why. A stock answer that hides an
-- AI failure ("What?") can be told apart from a real A-Life answer in the tester's console.txt.
M.inputLogAt = M.inputLogAt or {}
function M.inputNote(text, path, why)
    if M.settings.inputLog == false then return end
    local key = tostring(path) .. ":" .. tostring(why)
    local now = nowMs()
    if M.inputLogAt[key] ~= nil and now - M.inputLogAt[key] < 3000 then return end
    M.inputLogAt[key] = now
    log("input '" .. string.sub(tostring(text or ""), 1, 60) .. "' -> " .. tostring(path) .. (why and (" (" .. tostring(why) .. ")") or ""))
end

function M.tryDefer(player, listener, text, now, rowIntent)
    local s = M.settings
    local function no(why) M.inputNote(text, "A-Life", why); return false end
    if not s.enabled then return no("AI talk off") end
    if not M.aiHere() then return no("multiplayer: A-Life answers (mpAI off)") end
    if type(text) ~= "string" or string.match(text, "^%s*$") then return false end
    if type(listener) ~= "table" or type(listener.record) ~= "table" or listener.shell == nil then return no("nobody addressed") end
    local pa = PA()
    local talk, speech, data, intents = pa.Talk, pa.Speech, pa.DialogueData, pa.TalkIntents
    if not (fn(talk, "busy") and fn(talk, "stance") and fn(talk, "state") and fn(talk, "hold") and fn(speech, "say")
            and fn(speech, "playerKey") and type(data) == "table" and fn(data, "load") and fn(intents, "classify")) then
        return no("A-Life talk API missing")
    end
    local record, shell = listener.record, listener.shell
    local memory = type(record.memory) == "table" and record.memory or {}
    if type(memory.person) == "table" then return no("visitor at the door") end -- visitor (VisitorTalk.respond)
    local visit = pa.SafehouseVisit
    if fn(visit, "doorPeer") and visit.doorPeer(player, record.uid) ~= nil then return no("door talk") end
    if fn(visit, "live") and visit.live(record.uid) ~= nil then return no("safehouse visit") end
    if not M.bridgeAlive(now, player) then return no("AI bridge offline") end
    if fn(talk, "talkable") and not talk.talkable(shell, record) then return no("can't talk now (A-Life talkable)") end
    local stance = talk.stance(record, player)
    -- v3.2: hostile or mid-fight NPCs get short AI combat lines (ALifeLLMTalk_Hostile.lua); A-Life's own
    -- yes/no questions and preset intents still go to A-Life exactly as before
    if talk.busy(record, now) or stance == "hostile" or (M.isPaused and M.isPaused(record.uid)) then -- 0.5.1: paused = still a fight
        if rowIntent ~= nil then return no("menu row mid-fight") end -- 0.8.3: a picked row mid-fight stays A-Life's
        if M.hostileDefer then
            local d1, d2, d3 = M.hostileDefer(player, listener, text, now, stance)
            M.inputNote(text, d1 and "AI (fight)" or "A-Life", d1 and stance or "fight: A-Life's own answer or too soon")
            return d1, d2, d3
        end
        return no("fight")
    end

    data.load()
    local playerKey = speech.playerKey(player)
    local state = talk.state(playerKey, record.uid, now)
    local intent = rowIntent or intents.classify(text, state.pending ~= nil, data) -- 0.8.3: a picked row is its own intent
    if rowIntent ~= nil and fn(intents, "choiceById") then
        -- the AI hears the row as you'd say it ("How are you holding up?"), not its match words ("how are you")
        local okC, choice = pcall(intents.choiceById, rowIntent)
        if okC and type(choice) == "table" and type(choice.text) == "string" and choice.text ~= "" then
            text = string.gsub(choice.text, "%s*%[.-%]%s*", "")
        end
    end
    -- 0.5.2.11: soft classify for weaker models (fills nil intent/tone, forces unknown GIST)
    local soft = nil
    if rowIntent == nil and type(M.softPreprocess) == "function" then
        local okS, pre = pcall(M.softPreprocess, text, intent)
        if okS and type(pre) == "table" then
            soft = pre
            if pre.intent ~= nil then intent = pre.intent end
        end
    end
    -- an offer: remember what it names, so Jeem's hand gift only hands over what you said (ALifeGivenKeep)
    if intent == "OFFER_ITEM" and type(ALifeGivenKeep) == "table" and fn(ALifeGivenKeep, "noteOffer") then
        pcall(ALifeGivenKeep.noteOffer, player, text)
    end
    if M.isNative(intent, state) then return no("A-Life's own " .. tostring(intent or "question")) end
    -- Nov 16: plain greetings never need the AI (small models answered "Hmm.... Say again?"): A-Life answers them itself
    if rowIntent == nil and s.localGreet ~= false and (intent == "GREETING" or intent == "HOW_ARE_YOU")
            and select(2, string.gsub(text, "%S+", "")) <= 4 then
        return no("plain greeting: A-Life answers locally (" .. tostring(intent) .. ")")
    end

    -- A-Life's refusal window (TalkSocial: row.ru) still applies: they won't talk to you right now
    local social = pa.TalkSocial
    -- (a picked row already went through A-Life's own gate before Talk.respond)
    if rowIntent == nil and fn(social, "rowOf") and fn(social, "hours") and fn(social, "keyOf") and fn(social, "typed") then
        local row = social.rowOf(record, social.keyOf(player))
        if type(row) == "table" and row.ru ~= nil and social.hours() < row.ru then
            local line, why = social.typed(player, listener, "SMALL_TALK")
            if type(talk.escalating) == "table" and intent ~= nil and talk.escalating[intent] then
                M.escalate(record, shell, player, stance, 1, tostring(intent) .. " while not talking") -- they won't talk, but threats still count
            end
            -- 0.8.3 step 2: you kept at them after they ended it -> it costs you (server checks and caps it)
            if why == "talk_refused" and ALifeTalkEnd and type(ALifeTalkEnd.pushed) == "function" then
                pcall(ALifeTalkEnd.pushed, player, record.uid)
            end
            M.inputNote(text, "A-Life", "they won't talk to you right now (" .. tostring(why) .. ")")
            if line ~= nil then return true, line, why end
            return false
        end
    end

    -- 0.5.1.6: an empty line (just Enter / a name only) never goes to the AI ("you to Rajesh Garcia:")
    if type(text) ~= "string" or string.match(text, "^[%s%p]*$") then return false end
    local job = { mode = "reply", uid = tostring(record.uid), player = player, listener = listener, text = text,
        intent = intent, stance = stance, startMs = now, playerKey = playerKey, depth = 0 }
    if type(soft) == "table" then
        job.softTone = soft.tone
        job.softAct = soft.act
        job.softGist = soft.gistForce
        job.softReason = soft.reason
        job.softWeak = soft.weak == true
        job.softGistSoft = soft.gistSoft == true
        if type(soft.textNorm) == "string" and soft.textNorm ~= "" then job.textNorm = soft.textNorm end
    end
    job.rowIntent = rowIntent -- 0.8.3: a slow AI falls back to A-Life's answer for that same row
    job.sync = true
    M.submit(job)
    job.sync = nil
    if job.failed then return no("could not write the AI request") end -- could not build/write the request: A-Life answers right now
    M.inputNote(text, "AI", "intent " .. tostring(intent) .. (soft and soft.reason and (", " .. tostring(soft.reason)) or "")
        .. ((type(ALifeLanguage) == "table" and fn(ALifeLanguage, "looksForeign") and ALifeLanguage.looksForeign(text)) and ", other language" or ""))
    M.notePlayerLine(player, text)
    talk.hold(record, shell, player, now, s.fallbackMs + 4000)
    if fn(speech, "engineLine") then pcall(speech.engineLine, shell, "...", { 0.75, 0.75, 0.75 }) end
    M.metrics.asked = M.metrics.asked + 1
    return true, "...", "ai_pending"
end

----------------------------------------------------------------------------------------------------------------
-- Request queue: the bridge handles one request at a time. Player lines jump ahead of NPC chatter.
----------------------------------------------------------------------------------------------------------------
M.chatGen = 0
-- pre-1.0 (Joe Nov 20: "NPC chatter sends to server when not even nearby"): lines NPCs say out loud on their own go to
-- the AI only when a player can hear them. One gate for every such mode; player-driven modes never pass through it.
M.chatterModes = { ambient = true, banter = true, chime = true, event = true, death = true }
function M.chatterHeard(job)
    local reach = tonumber(M.settings.chatterHearTiles)
    if reach == nil or reach <= 0 then return true end
    local shell = type(job.listener) == "table" and job.listener.shell or nil
    if shell == nil and job.uid ~= nil then
        pcall(function() local talk = PA().Talk; if fn(talk, "shellFor") then shell = talk.shellFor(job.uid) end end)
    end
    if shell == nil then return false end -- not in the loaded world: nobody hears it
    local sx, sy = nil, nil
    pcall(function() sx, sy = shell:getX(), shell:getY() end)
    if sx == nil then return false end
    local heard = false
    local function near(p)
        if heard or p == nil then return end
        pcall(function() if (p:getX() - sx) ^ 2 + (p:getY() - sy) ^ 2 <= reach * reach then heard = true end end)
    end
    near(job.player)
    if not heard then for _, p in ipairs(M.players()) do near(p) end end
    return heard
end
function M.submit(job)
    local now = nowMs()
    if M.chatterModes[job.mode] and not M.chatterHeard(job) then
        M.metrics.farChatter = (M.metrics.farChatter or 0) + 1
        return nil
    end
    if (job.mode == "reply" or job.mode == "radio") and (type(job.text) ~= "string" or string.match(job.text, "^[%s%p]*$")) then
        M.emptyDropped = (M.emptyDropped or 0) + 1
        return nil -- 0.5.1.6: nothing was said
    end
    if job.mode ~= "reply" and job.gen == nil then job.gen = M.chatGen end
    if job.mode == "reply" then
        M.chatGen = M.chatGen + 1 -- NPC lines still waiting to be spoken are stale now
        M.chimeHold = nil
        local kept = {}
        for _, q in ipairs(M.queue) do
            if q.mode == "reply" or M.eventModes[q.mode] then kept[#kept + 1] = q
            else M.metrics.dropped = M.metrics.dropped + 1 end
        end
        M.queue = kept -- NPC chatter that was about to happen is stale now
        local cur = M.pending
        local instant = { reply = true, radio = true, gift = true, note = true, event = true, hear = true }
        if M.settings.replyFirst ~= false then instant.event, instant.hear = nil, nil end
        if cur ~= nil and (cur.mode == "event" or cur.mode == "hear") and not instant[cur.mode] then
            -- 0.5.2.5 [pt252u]: an overheard-line judgement / witness event used to make your line wait a whole model
            -- call (~1.5-2 s of "lag"). It gives way now and runs again right after your answer.
            M.pending = nil
            cur.id, cur.sentMs, cur.gen = nil, nil, M.chatGen
            M.replyLater = M.replyLater or {}
            M.replyLater[#M.replyLater + 1] = cur
            M.metrics.deferred = (M.metrics.deferred or 0) + 1
        elseif cur ~= nil and not instant[cur.mode] then
            -- v0.4.0: ANY background job (chime, ambient, reactions, grief, taunts, news) gives way to the player's
            -- line; 0.3.x waited for death/grief/taunt reactions to finish (up to ~9 s of "non-model" latency).
            M.pending = nil -- the bridge aborts it too when it sees the newer request
            if M.requeueModes[cur.mode] and not cur.requeued then
                -- a witness' reaction to a death, a nemesis confronting you...: asked again right after your answer
                cur.requeued, cur.id, cur.sentMs, cur.gen = true, nil, nil, M.chatGen
                M.afterReply = cur
            else
                M.metrics.dropped = M.metrics.dropped + 1
                -- 0.5.2.5: their own pain / injury line was cut off by your line -> the stock line, right away
                if M.settings.preemptStock ~= false and M.preemptStockModes[cur.mode] and type(cur.react) == "table"
                        and type(cur.react.fallback) == "string" and cur.react.fallback ~= "" then
                    local em = M.eventModes[cur.mode]
                    if em ~= nil and type(em.fallback) == "function" then pcall(em.fallback, cur)
                    else
                        pcall(function()
                            local me = M.refresh(cur)
                            if me ~= nil and M.say then M.say(me.shell, cur.player, cur.react.fallback, { record = me.record }) end
                        end)
                    end
                    M.metrics.preemptStock = (M.metrics.preemptStock or 0) + 1
                end
            end
        elseif cur ~= nil and cur.uid == job.uid and cur.mode == "reply" and type(cur.text) == "string" then
            job.text = cur.text .. " ... " .. tostring(job.text) -- typed again before the answer: send both lines together
            job.startMs = cur.startMs
            M.pending = nil
        end
        local merged = false
        for _, q in ipairs(M.queue) do
            if q.uid == job.uid and q.mode == "reply" and type(q.text) == "string" then
                q.text = q.text .. " ... " .. tostring(job.text)
                merged = true
                break
            end
        end
        if merged then job = { mode = "reply-merged" } end
    end
    if job.mode ~= "reply-merged" then M.queue[#M.queue + 1] = job end
    if (job.mode == "reply" or job.mode == "reply-merged") and M.replyLater ~= nil then
        for _, q in ipairs(M.replyLater) do M.queue[#M.queue + 1] = q end
        M.replyLater = nil
    end
    if (job.mode == "reply" or job.mode == "reply-merged") and M.afterReply ~= nil then
        M.queue[#M.queue + 1] = M.afterReply
        M.afterReply = nil
    end
    M.pump(now)
end
M.requeueModes = { death = true, grief = true, nemesis = true, warn = true, bulletin = true }
M.preemptStockModes = { injury_self = true, injury = true, last_words = true, taunt = true }

function M.pump(now)
    now = now or nowMs()
    while M.pending == nil and #M.queue > 0 do
        local m1 = M.queue[1].mode
        if M.chimeHold ~= nil and now < M.chimeHold and (m1 == "chime" or m1 == "banter" or m1 == "ambient") then return end
        local job = table.remove(M.queue, 1)
        if job.mode == "reply" and now - job.startMs >= M.settings.fallbackMs then
            M.metrics.fallback = M.metrics.fallback + 1
            safe(M.fallback, job)
        else
            local ok, request
            if type(ALifeSide) == "table" then ok, request = ALifeSide.with(job.player, M.requestFor, job, now) -- pre-1.0 MP: "you" = the job's player
            else ok, request = pcall(M.requestFor, job, now) end
            if ok and request ~= nil and M.drainILog then -- v0.4.0: interaction-log rows ride along with any request
                local okL, il = pcall(M.drainILog)
                if okL and il ~= nil then request.ilog = il end
            end
            if ok and request ~= nil and M.settings.pronounFix == false then request.pronounFix = false end -- 0.5.2.5
            if ok and request ~= nil and M.settings.orderRule == false then request.orderRule = false end -- 0.5.2.5
            if ok and request ~= nil then request.modv = M.VERSION end -- 0.5.2.6: the bridge logs a version mismatch too
            if ok and request ~= nil and M.deadFactsFor and M.settings.deathFacts ~= false then -- 0.5.2.6 [pt254u]: never cut
                local du = request.uid or job.uid or (job.listener and job.listener.record and job.listener.record.uid) or nil
                local okD, facts = pcall(M.deadFactsFor, du)
                if okD and facts ~= nil then request.deadFacts = facts end
            end
            if ok and request ~= nil and M.aiWrite(job, jsonEncode(request), request.id) then
                job.id, job.sentMs = request.id, now
                M.pending = job
            else
                if not ok then log("request error: " .. tostring(request)) end
                if job.mode == "reply" and job.sync then job.failed = true
                elseif job.mode == "reply" then safe(M.fallback, job)
                elseif M.eventModes[job.mode] and M.eventModes[job.mode].fallback then
                    safe(M.eventModes[job.mode].fallback, job)
                end
            end
        end
    end
end

function M.requestFor(job, now)
    local pa = PA()
    if M.eventModes[job.mode] and M.eventModes[job.mode].request then return M.eventModes[job.mode].request(job, now) end
    if job.mode == "ambient" and M.ambientRequest then return M.ambientRequest(job, now) end
    if job.mode == "reply" then
        local listener = M.refresh(job) or job.listener
        local said = job.textNorm or job.text
        local req = M.buildRequest(job.player, listener, said, job.intent, job.stance, now)
        if req == nil then return nil end
        -- 0.5.2.11: soft classifier / unknown GIST for weaker models
        if job.softGist then req.gist = job.softGist end
        if job.softReason then req.reason = job.softReason end
        if job.softTone then req.softTone = job.softTone end
        if job.softAct then req.softAct = job.softAct end
        if job.softWeak then req.weak = true end
        if job.softGistSoft then req.gistSoft = true end
        return req
    end
    -- chime / banter: an NPC who overheard a line
    local listener = M.refresh(job)
    if listener == nil then return nil end
    local talk = pa.Talk
    if talk.busy(listener.record, now) then return nil end
    local stance = talk.stance(listener.record, job.player)
    local req = M.buildRequest(job.player, listener, job.line, nil, stance, now)
    req.mode = job.mode
    local reg = pa.ActorRegistry
    local speaker = job.speakerUid and fn(reg, "read") and reg.read(job.speakerUid) or nil
    local myGroup = type(listener.record.memory) == "table" and listener.record.memory.groupId or nil
    req.line = { job.speakerUid and M.labelFor(pa, job.speakerUid, job.uid, myGroup) or "Them", job.line }
    req.lineTo = job.lineTo
    req.speakerUid = job.speakerUid
    if speaker ~= nil and fn(pa.Relations, "status") then
        local okS, st = pcall(pa.Relations.status, listener.record, speaker)
        if okS then req.toward = st end
        if fn(pa.Relations, "sameSide") then req.sameSide = pa.Relations.sameSide(listener.record, speaker) == true end
    end
    req.acts, req.actHints = {}, {}
    return req
end

----------------------------------------------------------------------------------------------------------------
-- Context for the prompt (only A-Life data + vanilla world state)
----------------------------------------------------------------------------------------------------------------
local function humanize(s)
    if type(s) ~= "string" or s == "" then return nil end
    return (string.gsub(s, "_", " "))
end

function M.labelFor(pa, uid, myUid, myGroup, playerKey)
    if uid == nil then return "someone" end
    if uid == myUid then return "You" end
    local reg = pa.ActorRegistry
    local other = fn(reg, "read") and reg.read(uid) or nil
    if type(other) ~= "table" then return "someone" end
    local om = type(other.memory) == "table" and other.memory or {}
    local name = fn(pa.Names, "of") and pa.Names.of(other) or nil
    if myGroup ~= nil and om.groupId == myGroup then return (name or "a mate") .. " (your group)" end
    return name or "a stranger"
end

function M.buildRequest(player, listener, text, intent, stance, now)
    local pa = PA()
    local talk, speech, names, roles = pa.Talk, pa.Speech, pa.Names, pa.DialogueRoles
    local opinion, social, catalog = pa.NpcOpinion, pa.TalkSocial, pa.Catalog
    local s = M.settings
    local record, shell = listener.record, listener.shell
    local memory = type(record.memory) == "table" and record.memory or {}
    local uid = tostring(record.uid)
    local playerKey = speech.playerKey(player)
    M.counter = M.counter + 1

    local npc = { stance = stance }
    npc.name = fn(names, "of") and names.of(record) or nil
    npc.first = type(memory.personFirst) == "string" and memory.personFirst or nil
    if fn(names, "knows") then npc.known = names.knows(record, playerKey) == true end
    local clock = fn(speech, "clock") and speech.clock() or {}
    if fn(roles, "describe") then
        local ok, who = pcall(roles.describe, record, clock.daysSurvived)
        if ok and type(who) == "table" then
            npc.role, npc.temper, npc.register, npc.sex = who.label, who.temperament, who.register, who.sex
        end
    end
    pcall(function() npc.sex = shell:isFemale() and "f" or "m" end) -- the body the player sees wins
    if fn(roles, "factsFor") then
        local ok, facts = pcall(roles.factsFor, record)
        if ok and type(facts) == "table" then npc.title, npc.rank = facts.name, facts.rank end
    end
    if fn(catalog, "faction") then
        local faction = catalog.faction(record.factionId)
        if type(faction) == "table" and type(faction.general) == "table" then npc.faction = faction.general.name end
    end
    npc.activity = humanize(record.activity)
    npc.goal = humanize(record.intent)
    if fn(talk, "destinationFor") then npc.dest = talk.destinationFor(record) end
    if fn(social, "mood") then npc.mood = social.mood(record, player) end
    if M.drunkOf then
        local okD, lvl, label = pcall(M.drunkOf, record.uid)
        if okD and type(lvl) == "number" and lvl > 0 then npc.drunk, npc.drunkLabel = lvl, label end
    end
    if fn(social, "hurt") then npc.hurt = social.hurt(record, shell) == true end
    if fn(social, "scared") then npc.scared = social.scared(record) == true end
    if fn(opinion, "payload") then
        local op = opinion.payload(record, player)
        if type(op) == "table" then npc.op, npc.opLabel, npc.opWhy = round(op.value or 0), op.label, op.reason end
    end

    local mates, mateCount, present = {}, 0, {}
    if fn(talk, "groupMembers") then
        for _, m in ipairs(talk.groupMembers(record, 20, shell)) do
            mateCount = mateCount + 1
            if #present < 12 and m.record ~= nil and m.record.uid ~= nil then present[#present + 1] = tostring(m.record.uid) end
            if #mates < s.matesInPrompt then
                mates[#mates + 1] = (fn(names, "of") and names.of(m.record)) or "a mate"
            end
        end
    end

    local world = { hour = clock.hour, day = clock.daysSurvived }
    pcall(function() world.minute = getGameTime():getMinutes() end)
    local sx, sy, sz = pos(shell)
    local px, py = pos(player)
    if fn(speech, "nearestTown") and px ~= nil then world.town = speech.nearestTown(px, py) end
    pcall(function()
        local cm = getClimateManager()
        world.rain = cm:getPrecipitationIntensity()
        world.fog = cm:getFogIntensity()
        world.tempC = math.floor(cm:getTemperature() + 0.5)
    end)
    pcall(function()
        local sq = shell:getCurrentSquare()
        world.indoors = sq ~= nil and not sq:isOutside()
        local room = sq and sq:getRoom()
        if room ~= nil then world.room = room:getName() end
    end)
    pcall(function()
        local list = getCell():getZombieList()
        local count = 0
        for i = 0, list:size() - 1 do
            local z = list:get(i)
            local zx, zy = z:getX(), z:getY()
            if (zx - sx) * (zx - sx) + (zy - sy) * (zy - sy) <= 225 and not z:isDead() and uidOf(z) == nil then
                count = count + 1
            end
        end
        world.zombies = count
    end)
    if fn(talk, "observations") then
        local ok, facts = pcall(talk.observations, record, shell, player, now)
        if ok and type(facts) == "table" then
            world.zContact = facts.recent_zombie_contact == true
            world.armed = facts.player_armed == true
        end
    end
    local you = {}
    pcall(function() you.sex = player:isFemale() and "f" or "m" end)
    pcall(function()
        local item = player:getPrimaryHandItem()
        if item ~= nil then you.holding = item:getDisplayName() end
    end)

    -- what was actually said nearby lately (A-Life lines incl. ambient banter, the player's lines, our AI lines)
    local heard = {}
    local myGroup = memory.groupId
    local r2 = s.heardRadius * s.heardRadius
    for i = #M.heard, 1, -1 do
        local h = M.heard[i]
        local hr2 = h.r and (h.r * h.r) or r2 -- v3.2: shouts carry farther than talk
        if now - (h.at or 0) <= s.heardMs and (h.x == nil or sx == nil or (h.x - sx) ^ 2 + (h.y - sy) ^ 2 <= hr2) then
            local who = h.player and "Them" or M.labelFor(pa, h.uid, uid, myGroup, playerKey)
            table.insert(heard, 1, { who, h.text, h.player and "player" or (h.uid or ""), h.loud and "shout" or nil })
            if h.uid ~= nil and #present < 16 then present[#present + 1] = tostring(h.uid) end
            if #heard >= s.heardInPrompt then break end
        end
    end

    -- earlier conversations with this NPC (older than the "heard" window; survives save/load)
    local earlier = {}
    local mem = M.memFor(uid)
    for i = #mem.lines, 1, -1 do
        local e = mem.lines[i]
        if type(e) == "table" and (e.ms == nil or now - e.ms > s.heardMs or now < e.ms) then
            table.insert(earlier, 1, { e.day or 0, e.you or "", e.me or "" })
            if #earlier >= s.earlierInPrompt then break end
        end
    end

    local acts, hints = M.availableActs(listener, player)
    local req = {
        id = tostring(nowMs()) .. "-" .. tostring(M.counter),
        npc = npc, mates = mates, mateCount = mateCount, world = world, you = you,
        heard = heard, earlier = earlier, said = text, aIntent = intent, acts = acts, actHints = hints,
        uid = uid, worldId = M.worldId(), presentUids = present, pos = sx and { math.floor(sx), math.floor(sy) } or nil,
    }
    -- v0.3.3 anti-repeat: their last 3 replies (the bridge forbids repeating them)
    pcall(function()
        local last, lines = {}, M.memFor(uid).lines or {}
        for i = #lines, 1, -1 do
            local me = lines[i].me
            if type(me) == "string" and me ~= "" then table.insert(last, 1, me) end
            if #last >= 3 then break end
        end
        if #last > 0 then req.lastReplies = last end
    end)
    for _, extra in ipairs(M.requestExtras) do
        local okX, errX = pcall(extra, req, player, listener, now)
        if not okX then log("prompt extra error: " .. tostring(errX)) end
    end
    return req
end

----------------------------------------------------------------------------------------------------------------
-- Reply handling
----------------------------------------------------------------------------------------------------------------
function M.parseReply(lines)
    local r = {}
    for _, line in ipairs(lines) do
        local k, v = string.match(line, "^(%w+)=(.*)$")
        if k ~= nil then r[k] = v end
    end
    if r.id == nil then return nil end
    r.d = clamp(round(tonumber(r.d) or 0), -10, 10)
    r.leave = r.leave == "true"
    if r.act == "" or r.act == "NONE" then r.act = nil end
    if r.tone == "" or r.tone == "NONE" or not M.tones[tostring(r.tone)] then r.tone = nil end
    r.text = r.text or ""
    r.fail = r.fail == "1"
    r.ask = r.ask == "true" -- 0.8.3 step 4: their line asks you something they want answered
    if r.gesture == "" then r.gesture = nil end -- 0.8.3 step 7: A-Life TalkGesture mood picked by the AI
    if r.cmd == "" or r.cmd == "NONE" then r.cmd = nil end -- 0.8.2 part 2: the command they agreed to (ALifeCommands id)
    if r.cmdItem == "" then r.cmdItem = nil end
    if r.want == "" or r.want == "NONE" or r.want == "none" then r.want = nil end -- 0.8.3 step 10: what they asked you for
    -- 0.8.3 step 3: "suggest=a|b|c" (bridge 0.8.3) -> list of things you could say next
    if type(r.suggest) == "string" and r.suggest ~= "" then
        local list = {}
        for part in string.gmatch(r.suggest, "[^|]+") do
            part = string.gsub(string.gsub(part, "^%s+", ""), "%s+$", "")
            if part ~= "" and #list < 3 then list[#list + 1] = string.sub(part, 1, 80) end
        end
        r.suggest = #list > 0 and list or nil
    else
        r.suggest = nil
    end
    return r
end

-- v0.4.2: the AI answered after A-Life already gave its own fallback line (slow model, Ollama busy). 0.4.1 threw
-- the late answer away, so A-Life's canned line ("Keep your distance") was all you saw. Now it is shown after
-- A-Life's line (so ours is the last word) as long as the NPC is still there and it's within lateReplyMs.
M.late = nil
function M.pollLate(now, r)
    local L = M.late
    if L == nil then return false end
    if now - L.p.startMs > M.settings.lateReplyMs then M.late = nil; return false end
    if r == nil or r.id ~= L.p.id then return false end
    M.late = nil
    if r.fail or r.text == "" then return true end
    local p = L.p
    local listener = M.refresh(p)
    if listener == nil or listener.shell == nil then return true end
    local px, py = pos(p.player)
    local sx, sy = pos(listener.shell)
    if px == nil or sx == nil or (px - sx) ^ 2 + (py - sy) ^ 2 > (M.settings.talkTiles + 4) ^ 2 then
        log("late AI reply dropped (" .. tostring(now - p.startMs) .. " ms): you walked away")
        return true
    end
    r.act, r.leave, r.cmd, r.want = nil, false, nil, nil -- A-Life already handled the turn; only the words (and the score) are added
    p.late = true
    log("late AI reply after " .. tostring(now - p.startMs) .. " ms: shown after A-Life's own line")
    M.metrics.late = (M.metrics.late or 0) + 1
    safe(M.finish, p, r)
    return true
end

-- 0.8.3 step 5: PACE. A reply that came back faster than a person would answer waits a moment (replyPace).
function M.paceMs(text)
    local words = 0
    for _ in string.gmatch(tostring(text or ""), "%S+") do words = words + 1 end
    return math.min(1800, 400 + 35 * words)
end

function M.poll()
    local now = nowMs()
    local h = M.held
    if h ~= nil and now >= h.at then
        M.held = nil
        safe(M.finish, h.p, h.r)
    end
    local p = M.pending
    if p == nil and M.late == nil then return end
    local lines = M.aiRead()
    local r = lines and M.parseReply(lines) or nil
    if r ~= nil and M.replySeen(r.id) then r = nil end -- 0.5.2.4: a reply id is shown once
    if M.late ~= nil and M.pollLate(now, r) then
        if r ~= nil then M.replyMark(r.id) end
        r = nil
    end
    if p == nil then return end
    if r ~= nil and r.id == p.id then M.replyMark(r.id) end
    local em = M.eventModes[p.mode]
    if em ~= nil then
        if r ~= nil and r.id == p.id then
            M.pending = nil
            if r.fail then
                if em.fallback then safe(em.fallback, p) end
            elseif em.finish then safe(em.finish, p, r) end
        elseif now - (p.sentMs or now) >= (em.finish and M.settings.fallbackMs or 3000) then
            M.pending = nil
            if em.fallback then safe(em.fallback, p) end
        end
        M.pump(now)
        return
    end
    local chatter = p.mode ~= "reply"
    if r ~= nil and r.id == p.id and r.fail then
        M.pending = nil
        if not chatter then
            log("AI gave no line: " .. tostring(r.why or "no reason sent (old bridge)")) -- 0.8.11.2 (Lava)
            p.aiFailed = tostring(r.why or "fail")
            M.metrics.fallback = M.metrics.fallback + 1
            safe(M.fallback, p)
        end
    elseif r ~= nil and r.id == p.id then
        M.pending = nil
        M.metrics.answered = M.metrics.answered + 1
        local need = (not chatter and M.settings.replyPace ~= false and M.held == nil) and M.paceMs(r.text) or 0
        if need > 0 and now - p.startMs < need then
            M.held = { p = p, r = r, at = p.startMs + need } -- shown by the next poll after that
            M.metrics.paced = (M.metrics.paced or 0) + 1
        elseif chatter then safe(M.finishChime, p, r) else safe(M.finish, p, r) end
    elseif chatter and now - (p.sentMs or now) >= M.settings.chimeTimeoutMs then
        M.pending = nil
        M.metrics.dropped = M.metrics.dropped + 1
    elseif not chatter and (tonumber(M.settings.thinkBeatMs) or 0) > 0 and now - p.startMs < M.settings.fallbackMs
            and now - (p.beatAt or p.startMs) >= (tonumber(M.settings.thinkBeatMs) or 0) then
        -- 0.8.3 step 5: still thinking - the grey "..." again (A-Life Speech.engineLine fades after a few seconds)
        p.beatAt = now
        local shell = type(p.listener) == "table" and p.listener.shell or nil
        local speech = PA() and PA().Speech or nil
        if shell ~= nil and fn(speech, "engineLine") then pcall(speech.engineLine, shell, "...", { 0.75, 0.75, 0.75 }) end
    elseif not chatter and now - p.startMs >= M.settings.fallbackMs then
        M.pending = nil
        M.metrics.fallback = M.metrics.fallback + 1
        log("no AI reply after " .. tostring(now - p.startMs) .. " ms, A-Life answers instead (the AI line is still shown if it comes within "
            .. tostring(math.floor(M.settings.lateReplyMs / 1000)) .. " s)")
        safe(M.fallback, p)
        if p.id ~= nil then M.late = { p = p } end
    end
    M.pump(now)
end

function M.refresh(p)
    local pa = PA()
    local reg, talk = pa.ActorRegistry, pa.Talk
    local old = p.listener or {}
    local record = fn(reg, "read") and reg.read(p.uid) or old.record
    if type(record) ~= "table" then return nil end
    local shell = fn(talk, "shellFor") and talk.shellFor(p.uid) or old.shell
    if shell == nil then return nil end
    if fn(pa.Speech, "alive") and pa.Speech.alive(shell) ~= true then return nil end
    return { record = record, shell = shell, distance = old.distance or 1, inCone = old.inCone }
end

function M.native(player, listener, text, now, choiceIntent)
    M.inNative = true
    M.inStockRespond = (M.inStockRespond or 0) + 1 -- 0.8.3 step 4b: A-Life's answer may still be swapped for a real-state line
    local realR = M.realRespond()
    local ok, said, reason = false, nil, nil
    if realR ~= nil then ok, said, reason = pcall(realR, player, listener, text, now, choiceIntent) else ok = true end
    M.inStockRespond = M.inStockRespond - 1
    M.inNative = false
    if not ok then log("A-Life respond error: " .. tostring(said)); return nil end
    return said, reason
end

-- 0.7.0.1: the AI is only slow (a cold model, or a 3D renderer like Project Viewpoint using the graphics card):
-- if A-Life doesn't understand the line either, its own answer is "I don't understand you", which is wrong. Then
-- they just take a moment ("Hm... give me a second") and the AI's line still comes if it arrives in time.
M.thinkingLines = M.thinkingLines or { "Hm... give me a second.", "Hold on, let me think.", "Uh... one sec.", "Hm.", "Let me think about that." }
function M.fallback(p)
    local listener = M.refresh(p)
    if listener == nil then return end
    local pa = PA() or {}
    local intents, data = pa.TalkIntents, pa.DialogueData
    local understood, intent = true, nil
    if fn(intents, "classify") and type(data) == "table" then
        pcall(function()
            if fn(data, "load") then data.load() end
            intent = intents.classify(p.text, false, data)
            understood = intent ~= nil
        end)
    end
    -- 0.8.11.2 (Lava): plain talk the AI was answering - A-Life's stock answer to it (an outlaw's greet bank opens with
    -- "What?") hid that the AI was only slow. Only A-Life's own handled lines / picked rows get A-Life's answer now.
    -- (the AI said it can't answer at all: A-Life's real answer, the console line above says why)
    local stockOk = p.rowIntent ~= nil or p.aiFailed ~= nil or (understood and M.isNative(intent, nil))
    M.inputNote(p.text, stockOk and ("A-Life (" .. (p.aiFailed and "AI failed" or "AI too slow") .. ")")
        or "thinking line (AI too slow)", tostring(intent))
    if not stockOk and fn(pa.Speech, "say") then
        local lines = M.thinkingLines
        local line = lines[(math.floor(nowMs() / 997) % #lines) + 1]
        local ok, said = pcall(pa.Speech.say, listener.shell, line, { face = p.player })
        if ok and said ~= false then M.metrics.thinking = (M.metrics.thinking or 0) + 1; return end
    end
    M.native(p.player, listener, p.text, nowMs(), p.rowIntent)
end

-- v0.3.3: A-Life's Speech.say stays silent while an NPC is "hurt" (hit in the last 5 s, hit-and-run, severe wound)
-- or downed - i.e. almost always mid-fight - and returns false. Hostile / combat lines were lost that way. Now:
-- A-Life's Speech.say first; if it refuses, the line is drawn directly with A-Life's own Speech.display (its speech
-- bubbles + chat log), then the engine's addLineChatElement / Say as last resorts. Combat lines are re-offered
-- once a moment later (A-Life's pain barks clear an NPC's other bubbles; a still-visible bubble is just merged).
M.reshowQueue = {}

-- 0.5.2.3: every line we put on screen goes through cleanText - raw markup from a model / a saved line / another mod
-- (\color{255,0,0}, <RGB:1,0,0>, <SIZE:large>, [col=..], [img=..]) is stripped, so it never shows as literal text.
-- Cheap: a few gsubs on a short string, only when a line is shown. Settings: cleanMarkup = false turns it off.
function M.cleanText(text)
    if type(text) ~= "string" or text == "" then return text end
    if M.settings and M.settings.cleanMarkup == false then return text end
    if string.find(text, "[\\<%[{]") == nil then return text end
    local t = text
    t = string.gsub(t, "\\+color%s*%b{}", "")
    t = string.gsub(t, "\\+[%a]+%s*%b{}", "")
    t = string.gsub(t, "<%s*[Rr][Gg][Bb]%s*:?[^>]*>", "")
    t = string.gsub(t, "<%s*/?%s*[%u][%u_]*%s*:?[^>]*>", "")
    t = string.gsub(t, "%[%s*/?%s*col%s*=?[^%]]*%]", "")
    t = string.gsub(t, "%[%s*img%s*=[^%]]*%]", "")
    t = string.gsub(t, "%[%s*/%s*%]", "")
    t = string.gsub(t, "%s%s+", " ")
    t = string.gsub(t, "^%s+", "")
    t = string.gsub(t, "%s+$", "")
    if t == "" then return text end
    return t
end

-- 0.5.2.3: reshow without stacking. A-Life's bubbles only merge the same text within 400 ms, so our +1.2 s / +3 s
-- combat reshows and the guard reshow drew a second (third) copy of a line that was still on screen (video 1025,
-- 0:48-0:57). Now: still the newest live bubble on that NPC -> skip; still live but buried under a newer line -> the
-- old copy fades and ours is drawn on top (one copy). Settings: reshowDedupe = false gives the old behaviour.
----------------------------------------------------------------------------------------------------------------
-- 0.5.2.4 SPEECH ONCE [pt249u] "npcs are repeating dialogue in 3s". Root cause: a combat line (every line while the
-- NPC is fighting, fleeing, afraid or recovering - A-Life's Talk.busy / Speech.quietReason) was queued for two
-- reshows (+1.2 s, +3 s). 0.5.2.2 drew both unconditionally = 3 copies; 0.5.2.3 skipped a reshow only when it found
-- the exact text still live in A-Life's bubbles - but a line shorter than ~27 characters has already timed out at
-- +3 s (A-Life holds 2.4 s minimum), a bubble of an NPC off screen is never stored, and with A-Life's bubbles off
-- (engine overhead text) nothing can be found at all, so it drew the line again ("fail open"). The guard reshow
-- (an A-Life line over ours, max 2) had the same gap. Now:
--  * every line we show is remembered per NPC (words normalised: case, punctuation, markup ignored) together with
--    the bubble A-Life actually built for it (startMs/endMs, found by object, not by text);
--  * the same words on the same NPC within speechOnceMs (8 s) are dropped - from M.say, ownSay and from any other
--    Speech.say caller (a leftover file, the patch) - and one reply id is shown once;
--  * a reshow only draws when that very bubble was removed or pushed out BEFORE its own end (A-Life pain bark,
--    3-bubble limit) or is buried under a newer line (old copy fades, ours on top). Timed out naturally, still on
--    top, or not visible to us (engine text, off screen, no bubble module) -> no reshow ("fail closed").
-- Off: speechOnce = false (0.5.2.3 behaviour), reshowDedupe = false (0.5.2.2 behaviour).
----------------------------------------------------------------------------------------------------------------
M.spoken = {}
M.spokenN = 0
M.replyDone, M.replyOrder = M.replyDone or {}, M.replyOrder or {}
function M.normLine(text)
    if type(text) ~= "string" then return "" end
    local t = string.lower(text)
    t = string.gsub(t, "[^%w]+", " ")
    t = string.gsub(t, "^ +", "")
    t = string.gsub(t, " +$", "")
    return t
end
function M.sameLine(a, b)
    if a == nil or b == nil or a == "" or b == "" then return false end
    if a == b then return true end
    if #a >= 12 and #b >= 12 then
        return string.find(a, b, 1, true) ~= nil or string.find(b, a, 1, true) ~= nil
    end
    return false
end
function M.bubblesNow()
    local bubbles = PA().SpeechBubbles
    local now = nil
    if type(bubbles) == "table" then pcall(function() if fn(bubbles, "now") then now = tonumber(bubbles.now()) end end) end
    return now
end
-- the newest live bubble of this NPC built at/after sinceB; one with the same words wins
function M.findEntry(shell, text, sinceB)
    local bubbles = PA().SpeechBubbles
    if shell == nil or type(bubbles) ~= "table" or type(bubbles.layers) ~= "table" then return nil end
    local norm = M.normLine(text)
    local best, bestAny = nil, nil
    for _, layer in pairs(bubbles.layers) do
        local entries = type(layer) == "table" and layer.entries or nil
        local count = type(layer) == "table" and tonumber(layer.count) or 0
        if type(entries) == "table" and count ~= nil then
            for i = count, 1, -1 do
                local e = entries[i]
                if type(e) == "table" and e.shell == shell and e.fading ~= true
                        and (sinceB == nil or (tonumber(e.startMs) or -1) >= sinceB) then
                    if best == nil and M.sameLine(M.normLine(e.text), norm) then best = e end
                    if bestAny == nil then bestAny = e end
                end
            end
        end
    end
    if best ~= nil then return best end
    if sinceB ~= nil then return bestAny end
    return nil
end
-- where is this exact bubble now: present?, live?, buried under a newer line of the same NPC?
function M.entryWhere(entry, shell)
    local bubbles = PA().SpeechBubbles
    if type(bubbles) ~= "table" or type(bubbles.layers) ~= "table" then return false, false, false end
    for _, layer in pairs(bubbles.layers) do
        local entries = type(layer) == "table" and layer.entries or nil
        local count = type(layer) == "table" and tonumber(layer.count) or 0
        if type(entries) == "table" and count ~= nil then
            for i = 1, count do
                if entries[i] == entry then
                    local buried = false
                    for j = i + 1, count do
                        local o = entries[j]
                        if type(o) == "table" and o.shell == shell and o.fading ~= true then buried = true end
                    end
                    return true, entry.fading ~= true, buried
                end
            end
        end
    end
    return false, false, false
end
function M.spokenFind(shell, text, now)
    if shell == nil or M.settings.speechOnce == false then return nil end
    local list = M.spoken[shell]
    if list == nil then return nil end
    local norm = M.normLine(text)
    local win = tonumber(M.settings.speechOnceMs) or 8000
    for i = #list, 1, -1 do
        local sp = list[i]
        if now >= sp.atMs and now - sp.atMs < win and M.sameLine(sp.norm, norm) then return sp end
    end
    return nil
end
function M.spokenPrune(now)
    local win = (tonumber(M.settings.speechOnceMs) or 8000) * 2
    local keep, n = {}, 0
    for sh, list in pairs(M.spoken) do
        local last = list[#list]
        if last ~= nil and now - last.atMs < win then keep[sh] = list; n = n + 1 end
    end
    M.spoken, M.spokenN = keep, n
end
function M.spokenNote(shell, text, now, sinceB)
    if shell == nil or type(text) ~= "string" then return nil end
    local list = M.spoken[shell]
    if list == nil then
        if M.spokenN >= 48 then M.spokenPrune(now) end
        list = {}
        M.spoken[shell] = list
        M.spokenN = M.spokenN + 1
    end
    local sp = { norm = M.normLine(text), text = text, atMs = now }
    local okE, e = pcall(M.findEntry, shell, text, sinceB)
    if okE and type(e) == "table" then sp.entry = e; sp.endMs = tonumber(e.endMs) end
    list[#list + 1] = sp
    while #list > 4 do table.remove(list, 1) end
    return sp
end
function M.dupDropped(shell, text, where)
    M.metrics.dupDropped = (M.metrics.dupDropped or 0) + 1
    local now = nowMs()
    if now - (M.dupLogAt or -1e12) >= 30000 then
        M.dupLogAt = now
        log("duplicate line dropped (" .. tostring(where) .. ": \"" .. string.sub(tostring(text), 1, 50) .. "\" was shown on that NPC "
            .. "moments ago; " .. tostring(M.metrics.dupDropped) .. " dropped so far)")
    end
end
-- a reply id is shown once (a reply file read twice, a late copy) - kept for the last 64 ids
function M.replySeen(id)
    if id == nil or M.settings.speechOnce == false then return false end
    return M.replyDone[tostring(id)] == true
end
function M.replyMark(id)
    if id == nil then return end
    id = tostring(id)
    if M.replyDone[id] then return end
    M.replyDone[id] = true
    M.replyOrder[#M.replyOrder + 1] = id
    while #M.replyOrder > 64 do M.replyDone[table.remove(M.replyOrder, 1)] = nil end
end
-- reshow decision: "top" / "buried" / "cleared" (removed early) / "expired" / "unknown"
function M.reshowState(q, bnow)
    local sp = q.spoken
    if type(sp) == "table" and sp.entry ~= nil then
        local present, live, buried = M.entryWhere(sp.entry, q.shell)
        local early = bnow ~= nil and sp.endMs ~= nil and bnow < sp.endMs - 300
        if present and live then return buried and "buried" or "top" end
        if early then return "cleared" end
        return "expired"
    end
    local st = M.bubbleState(q.shell, q.text)
    if st ~= nil then return st end
    return "unknown"
end

function M.bubbleState(shell, text)
    if shell == nil or type(text) ~= "string" then return nil end
    local bubbles = PA().SpeechBubbles
    if type(bubbles) ~= "table" or type(bubbles.layers) ~= "table" then return nil end
    local now = nil
    pcall(function() if fn(bubbles, "now") then now = bubbles.now() end end)
    local found, newer = {}, false
    for _, layer in pairs(bubbles.layers) do
        local entries = type(layer) == "table" and layer.entries or nil
        local count = type(layer) == "table" and tonumber(layer.count) or 0
        if type(entries) == "table" then
            local seenOurs = false
            for i = 1, count do
                local e = entries[i]
                if type(e) == "table" and e.shell == shell and e.fading ~= true and (now == nil or e.endMs == nil or e.endMs > now) then
                    if e.text == text or (M.settings.speechOnce ~= false and M.sameLine(M.normLine(e.text), M.normLine(text))) then
                        found[#found + 1] = e; seenOurs = true
                    elseif seenOurs then
                        newer = true
                    end
                end
            end
        end
    end
    if #found == 0 then return nil end
    return newer and "buried" or "top", found
end

function M.inCombat(shell, record)
    local pa = PA()
    local speech, talk = pa.Speech, pa.Talk
    local reason = nil
    if fn(speech, "quietReason") then pcall(function() reason = speech.quietReason(shell, record, nil) end) end
    if reason ~= nil then return true, reason end
    if type(record) == "table" and fn(talk, "busy") then
        local ok, busy = pcall(talk.busy, record, nowMs())
        if ok and busy == true then return true, "fighting" end
    end
    return false, nil
end

function M.forceShow(shell, player, text, why)
    local pa = PA()
    local speech = pa.Speech
    if shell == nil or type(text) ~= "string" or text == "" then return false end
    text = M.cleanText(text)
    if fn(speech, "alive") and speech.alive(shell) ~= true then return false end
    if pa.AudioPolicy and fn(pa.AudioPolicy, "caption") and pa.AudioPolicy.caption(text) == nil then return false end
    if player ~= nil and fn(speech, "face") then pcall(speech.face, shell, player) end
    local uid = fn(speech, "variable") and speech.variable(shell, "ALifeUID") or nil
    local shown, how = false, nil
    if fn(speech, "display") then
        pcall(function()
            local color = fn(speech, "colorFor") and speech.colorFor(uid, nil) or { 1, 1, 1 }
            shown = speech.display(shell, text, color, "directed", uid) == true
        end)
        if shown then how = "Speech.display" end
    end
    if not shown then shown = pcall(function() shell:addLineChatElement(text, 1, 1, 1) end); if shown then how = "addLineChatElement" end end
    if not shown then shown = pcall(function() shell:Say(text) end); if shown then how = "Say" end end
    if shown then
        M.metrics.forced = (M.metrics.forced or 0) + 1
        pcall(M.noteNpcLine, shell, text)
        log("line shown directly (" .. tostring(how) .. "; A-Life's Speech.say refused: " .. tostring(why) .. ")")
    end
    return shown
end

-- v0.4.2: our line stays the last word. A-Life keeps talking on its own (careful-stance "keep your distance"
-- warnings and nags, panic and contact barks, a fallback answer): for guardMs after our line, an A-Life line drawn
-- on the same NPC gets ours drawn again right after it. A-Life's line is never blocked - it still shows and logs.
M.guards = {}
function M.guardLine(shell, text, spoken)
    if shell == nil then return end
    local now = nowMs()
    for k, g in pairs(M.guards) do if now > g.untilMs then M.guards[k] = nil end end
    M.guards[shell] = { text = text, untilMs = now + M.settings.guardMs, reshows = 0, spoken = spoken }
end
-- 0.5.2.3: our OWN lines that go straight to A-Life's Speech.say (chimes, ambient chatter, NPC-NPC talk, radio
-- near, follow answers, wound grunts) were taken for "an A-Life line drawn over our reply" - the console of video 1025
-- shows it 5 times in 2 minutes ("...Say no more.", "Round and round we go, like a carousel"): the NPC's earlier
-- reply was drawn again over its own newer line, so old and new replies bounced (the 0:48-0:57 burst). Now they are
-- flagged as ours; a newer full line also ends the guard of the older one (it is the last word now).
function M.ownSay(shell, text, opts, keepGuard)
    if shell == nil or type(text) ~= "string" or text == "" then return false end
    local speech = PA().Speech
    if not fn(speech, "say") then return false end
    text = M.cleanText(text)
    local now = nowMs()
    if M.spokenFind(shell, text, now) then M.dupDropped(shell, text, "own line"); return true end
    if not keepGuard then M.guards[shell] = nil end
    local sinceB = M.bubblesNow()
    M.ownShowing = true
    local ok, res = pcall(speech.say, shell, text, opts or {})
    M.ownShowing = false
    if ok and res == true and M.settings.speechOnce ~= false then pcall(M.spokenNote, shell, text, now, sinceB) end
    return ok and res
end

-- 0.8.2.1: true when A-Life says this NPC is hurt, downed or fighting and the yieldBusy setting is on.
function M.yields(shell, record)
    if M.settings.yieldBusy == false then return false, nil end
    return M.inCombat(shell, record)
end

function M.onForeignLine(shell, text, how)
    if M.ownShowing or shell == nil then return end
    local g = M.guards[shell]
    if g == nil then return end
    local now = nowMs()
    if now > g.untilMs then M.guards[shell] = nil; return end
    -- 0.8.2.1 [Bona-fide log f:1788/f:1875]: a fight started after our reply -> A-Life's bark wins, guard ends
    local busy, busyWhy = M.yields(shell, nil)
    if busy then
        M.guards[shell] = nil
        M.metrics.yielded = (M.metrics.yielded or 0) + 1
        log("A-Life line kept over our reply (" .. tostring(busyWhy) .. "): \"" .. string.sub(tostring(text), 1, 50) .. "\"")
        return
    end
    if text == g.text or g.reshows >= 2 or #M.reshowQueue >= 12 then return end
    if M.settings.speechOnce ~= false and M.sameLine(M.normLine(text), M.normLine(g.text)) then return end
    g.reshows = g.reshows + 1
    M.reshowQueue[#M.reshowQueue + 1] = { shell = shell, text = g.text, at = now + 350, spoken = g.spoken }
    M.metrics.reshown = (M.metrics.reshown or 0) + 1
    log("A-Life line drawn over our reply (" .. tostring(how) .. ": \"" .. string.sub(tostring(text), 1, 50) .. "\"); ours shown again after it")
end

function M.reshowTick(now)
    if #M.reshowQueue == 0 then return end
    local keep = {}
    local bubbles = PA().SpeechBubbles
    for _, q in ipairs(M.reshowQueue) do
        if now >= q.at then
            local speech = PA().Speech
            local state, found = nil, nil
            local once = M.settings.reshowDedupe ~= false and M.settings.speechOnce ~= false
            if once then
                local okS, st = pcall(M.reshowState, q, M.bubblesNow())
                state = okS and st or "unknown"
                if state == "buried" then
                    if type(q.spoken) == "table" and q.spoken.entry ~= nil then found = { q.spoken.entry }
                    else local okB, _, fd = pcall(M.bubbleState, q.shell, q.text); if okB then found = fd end end
                end
                if state == "unknown" and not M.unknownLogged then
                    M.unknownLogged = true
                    log("reshow skipped: A-Life's bubble for that line can't be seen (engine overhead text, NPC off screen or bubbles off) - never drawn twice")
                end
            elseif M.settings.reshowDedupe ~= false then
                local okS, st, fd = pcall(M.bubbleState, q.shell, q.text)
                if okS then state, found = st, fd end
            end
            if state == "top" or state == "expired" or state == "unknown" or M.yields(q.shell, nil) then
                M.metrics.reshowSkipped = (M.metrics.reshowSkipped or 0) + 1
            elseif fn(speech, "alive") and speech.alive(q.shell) == true then
                if state == "buried" and type(found) == "table" then
                    local bnow = nil
                    pcall(function() bnow = bubbles.now() end)
                    for _, e in ipairs(found) do
                        pcall(function()
                            if fn(bubbles, "fadeOut") and bnow ~= nil then bubbles.fadeOut(e, bnow) else e.fading = true end
                        end)
                    end
                end
                local uid = fn(speech, "variable") and speech.variable(q.shell, "ALifeUID") or nil
                M.ownShowing = true
                local done = false
                local sinceB = M.bubblesNow()
                if fn(bubbles, "show") then
                    pcall(function()
                        local color = fn(speech, "colorFor") and speech.colorFor(uid, nil) or nil
                        done = bubbles.show(q.shell, q.text, color, "directed", uid) == true -- no chat mirror: the log has it
                    end)
                end
                -- engine overhead text stacks every call; 0.5.2.4 never adds it from a reshow (once = on)
                if not done and not once then pcall(function() q.shell:addLineChatElement(q.text, 1, 1, 1) end) end
                M.ownShowing = false
                if done and once and type(q.spoken) == "table" then
                    local okE, e = pcall(M.findEntry, q.shell, q.text, sinceB)
                    if okE and type(e) == "table" then q.spoken.entry = e; q.spoken.endMs = tonumber(e.endMs) end
                    M.metrics.reshowDrawn = (M.metrics.reshowDrawn or 0) + 1
                end
            end
        else
            keep[#keep + 1] = q
        end
    end
    M.reshowQueue = keep
end

function M.say(shell, player, text, opts)
    opts = opts or {}
    local pa = PA()
    local speech = pa.Speech
    if shell == nil or type(text) ~= "string" or text == "" then return false end
    text = M.cleanText(text)
    if text == "" then return false end
    local now = nowMs()
    if M.spokenFind(shell, text, now) then M.dupDropped(shell, text, "reply"); return true end
    local record = opts.record
    local combat, why = M.inCombat(shell, record)
    local yield = combat and M.settings.yieldBusy ~= false
    local sinceB = M.bubblesNow()
    M.ownShowing = true
    local ok, res = pcall(speech.say, shell, text, { face = player })
    local shown = ok and res == true
    if not shown and yield and ok then
        -- 0.8.2.1: A-Life refused because they are hurt / downed / fighting -> they don't answer now (no forced line)
        M.ownShowing = false
        M.metrics.yielded = (M.metrics.yielded or 0) + 1
        log("line not shown: A-Life's Speech.say refused (" .. tostring(why) .. "), not forced")
        return false
    end
    if not shown then shown = M.forceShow(shell, player, text, ok and (why or "refused") or tostring(res)) end
    M.ownShowing = false
    local sp = nil
    if shown and M.settings.speechOnce ~= false then
        local okN, r = pcall(M.spokenNote, shell, text, now, sinceB)
        if okN then sp = r end
    end
    if shown and yield then return shown end -- 0.8.2.1: busy -> shown once, no guard, no reshows
    if shown then M.guardLine(shell, text, sp) end
    if shown and (combat or opts.combat) and #M.reshowQueue < 12 then
        -- twice: A-Life's own combat barks ("I ain't finished") are drawn right after ours and push it out.
        -- 0.5.2.4: each one only draws if that bubble really was pushed out early (reshowState)
        M.reshowQueue[#M.reshowQueue + 1] = { shell = shell, text = text, at = now + 1200, spoken = sp }
        M.reshowQueue[#M.reshowQueue + 1] = { shell = shell, text = text, at = now + 3000, spoken = sp }
    end
    return shown
end

function M.dispatch(act, player, listener, text, now, r)
    local pa = PA()
    local talk, opinion, social = pa.Talk, pa.NpcOpinion, pa.TalkSocial
    M.metrics.acts = M.metrics.acts + 1
    log("AI picked A-Life action " .. act)
    if act == "PARTY_JOIN" and M.partyInviteWords and M.partyInviteWords(text) then
        -- 0.5.1.3: the player invited THEM ("join me / join my party / roll with me"); A-Life's PARTY_JOIN would put the
        -- player into the NPC's group ("You joined the group.") instead. Route it to our party recruit.
        if M.partyLog then M.partyLog("AI picked PARTY_JOIN for an invite (\"" .. string.sub(tostring(text), 1, 60) .. "\") - recruiting them into YOUR party instead of joining theirs") end
        if M.partyRecruitNow then pcall(M.partyRecruitNow, listener, player, "AI act") end
        return nil
    end
    if act == "WALK_WITH_ME" or act == "WALK_STOP" then
        -- mirrors Talk.choose (ALifeTalk.lua): NpcOpinion.talkRefusal first, then Talk.walkWith
        if act == "WALK_WITH_ME" and fn(opinion, "talkRefusal") then
            local refusal = opinion.talkRefusal(player, listener.record, { id = act })
            if refusal ~= nil then M.say(listener.shell, player, refusal); return refusal end
        end
        local ok, words = talk.walkWith(player, listener, act)
        if ok and act == "WALK_WITH_ME" and M.followStart then pcall(M.followStart, listener, player) end
        if ok and act == "WALK_STOP" and M.followEnd then pcall(M.followEnd, listener.record.uid) end
        -- "wait here": a party member holds (else the party renews their follow order and they walk right back)
        if ok and act == "WALK_STOP" and M.partyCommand and M.partyMembers then
            local uid = tostring(listener.record.uid)
            for _, m in ipairs(M.partyMembers(player) or {}) do
                if tostring(m) == uid then pcall(M.partyCommand, uid, "hold", player); break end
            end
        end
        if ok then
            local line = (r.text ~= "" and r.text) or words
            M.say(listener.shell, player, line)
            return line
        end
        -- v0.3.1: A-Life said no (e.g. "not_walking" for WALK_STOP when they weren't following you). v0.3.0 spoke a
        -- hard-coded "Can't do that right now." here, which replaced the AI's real answer. Now: nothing is said
        -- here and M.finish speaks the AI's line instead.
        log("A-Life declined " .. act .. " (" .. tostring(words) .. "); the AI's own line is used")
        return nil
    end
    -- same gate the typed path uses (Talk.respond -> TalkSocial.typed), then A-Life's own handler
    if fn(social, "typed") then
        local line = social.typed(player, listener, act)
        if line ~= nil then return line end
    end
    local said = M.native(player, listener, text, now, act)
    if said == nil or said == "" then
        log("A-Life gave no line for " .. act .. "; the AI's own line is used")
        return nil
    end
    return said
end

function M.humanDelta(mem, raw, value, applied, now, tone)
    local s = M.settings
    local scale = 1
    local social = PA().TalkSocial
    local cfg = fn(social, "config") and social.config() or nil
    if cfg ~= nil and type(cfg.scale) == "number" then scale = cfg.scale end
    local d = raw
    if raw < 0 then
        local streak = (now - (mem.negAt or 0) <= s.negStreakMs) and (mem.neg or 0) or 0
        if streak == 0 and value >= s.friendAt and raw >= -3 then
            d = raw * 0.5                       -- one-off jab between friends
        else
            d = raw * math.min(2.5, 1 + 0.5 * streak) -- repeated rudeness compounds
        end
        mem.neg, mem.negAt, mem.pos = streak + 1, now, 0
    elseif raw > 0 then
        mem.pos = (mem.pos or 0) + 1
        if mem.pos > 3 then d = raw * 0.5 end   -- words are cheap: sweet talk has diminishing returns
        mem.neg = 0
    end
    d = d * scale
    -- A-Life already applied 'applied' through TalkSocial.ask; only add what is missing, never fight its sign
    local extra = 0
    if applied ~= 0 and ((applied > 0) ~= (d > 0)) then
        extra = 0
    elseif math.abs(d) > math.abs(applied) then
        extra = d - applied
    end
    extra = round(extra)
    if extra < -s.maxNegPerLine then extra = -s.maxNegPerLine end
    if extra > 0 and cfg ~= nil then
        -- A-Life's own limits for talk: word ceiling and daily cap (TalkSocial.config)
        local ceiling = tonumber(cfg.ceiling) or 40
        if value + applied + extra > ceiling then extra = math.max(0, ceiling - value - applied) end
        local day = 0
        pcall(function() day = getGameTime():getNightsSurvived() end)
        if mem.posDay ~= day then mem.posDay, mem.posSum = day, 0 end
        local room = (tonumber(cfg.capDay) or 12) - (mem.posSum or 0)
        extra = math.max(0, math.min(extra, room))
        mem.posSum = (mem.posSum or 0) + extra
    end
    return extra, d
end

-- A-Life's hostility ladder (Talk.escalate, ALifeTalk.lua): neutral/friendly -> careful for a few minutes;
-- careful -> ModuleCareful.noteShout, whose 5th strike in 2 minutes turns the group hostile (turnGroup).
-- 0.8.11.2 hostile needs 2 signs: one line (one rude word, one "get outta here", a misheard word) never moves
-- anyone toward hostile. Signs from the same player add up inside hostileSignWindowMs; only when they reach
-- hostileSigns does A-Life's ladder run. A first sign leaves them wary (the AI line already shows it).
M.settings.hostileSigns = M.settings.hostileSigns or 2
M.settings.hostileSignWindowMs = M.settings.hostileSignWindowMs or 180000
M.hostileSignRows = M.hostileSignRows or {}
do
    M.fileKeys = M.fileKeys or {}
    for _, k in ipairs({ "hostileSigns", "hostileSignWindowMs", "fightWarnTalk", "inputLog" }) do
        local have = false
        for _, x in ipairs(M.fileKeys) do if x == k then have = true end end
        if not have then M.fileKeys[#M.fileKeys + 1] = k end
    end
end
if M.settings.fightWarnTalk == nil then M.settings.fightWarnTalk = true end -- "get outta here!" mid-fight = a warning
if M.settings.inputLog == nil then M.settings.inputLog = true end          -- one console line per typed line: who answered and why

-- weight: how strong this sign is (1 = one rude line / one bare threat word; 2 = a threat with a tail or a gun on them)
-- returns true when the signs are enough; false = noted only
function M.hostileSign(record, player, weight, why, now)
    now = now or nowMs()
    local need = tonumber(M.settings.hostileSigns) or 2
    if need <= 1 then return true end
    local key = tostring(type(record) == "table" and record.uid or record) .. ":"
    pcall(function() key = key .. tostring(PA().Speech.playerKey(player)) end)
    local row = M.hostileSignRows[key] or {}
    local keep = {}
    local window = tonumber(M.settings.hostileSignWindowMs) or 180000
    local sum = 0
    for _, s in ipairs(row) do if now - s.at <= window then keep[#keep + 1] = s; sum = sum + s.w end end
    local w = tonumber(weight) or 1
    keep[#keep + 1] = { at = now, w = w, why = tostring(why or "?") }
    sum = sum + w
    if sum >= need then
        M.hostileSignRows[key] = nil
        log("hostile signs " .. tostring(sum) .. "/" .. tostring(need) .. " (" .. tostring(why) .. "): A-Life's ladder runs")
        return true
    end
    while #keep > 8 do table.remove(keep, 1) end
    M.hostileSignRows[key] = keep
    log("hostile sign " .. tostring(sum) .. "/" .. tostring(need) .. " (" .. tostring(why) .. "): noted, no escalation yet")
    return false
end

function M.escalate(record, shell, player, stance, weight, why)
    local talk = PA().Talk
    if not fn(talk, "escalate") then return end
    if not M.hostileSign(record, player, weight or 1, why or "rude line") then return end
    local context = { stance = stance }
    if fn(talk, "later") then
        talk.later(1800, function() talk.escalate(record, shell, player, context, nowMs()) end)
    else
        talk.escalate(record, shell, player, context, nowMs())
    end
end

function M.finish(p, r)
    local pa = PA()
    local talk, speech, opinion, social, names = pa.Talk, pa.Speech, pa.NpcOpinion, pa.TalkSocial, pa.Names
    local listener = M.refresh(p)
    if listener == nil then return end
    local player, record, shell = p.player, listener.record, listener.shell
    local now = nowMs()
    -- v0.4.0 latency breakdown: queue = waiting for an earlier job, bridge = bridge+model time it reported,
    -- exchange = the rest (file write, bridge pick-up, reply pick-up)
    local queued = (p.sentMs or p.startMs) - p.startMs
    local bridgeMs = math.floor(tonumber(r.ms) or 0)
    log(string.format("reply in %d ms (queue %d, bridge %d, exchange %d): d=%s tone=%s act=%s", now - p.startMs, queued,
        bridgeMs, math.max(0, now - (p.sentMs or p.startMs) - bridgeMs), tostring(r.d), tostring(r.tone), tostring(r.act)))
    if p.hostile and M.finishHostile then return M.finishHostile(p, r, listener) end
    -- v0.3.3: a fight started (or they turned hostile) while the AI was answering. 0.3.2 dropped the AI's line here
    -- (A-Life's typed path refuses hostile NPCs), so replies like "Whoa, that's it..." never showed. The combat
    -- path speaks it and still applies the score.
    if talk.busy(record, now) or talk.stance(record, player) == "hostile" then
        talk.releaseHold(record.uid, p.playerKey)
        if M.finishHostile then return M.finishHostile(p, r, listener) end
        if r.text ~= "" then M.say(shell, player, r.text, { record = record, combat = true }) end
        return
    end
    local stance = talk.stance(record, player)

    local mem = M.memFor(p.uid)
    local said = nil
    local act = r.act
    -- v0.3.1 sanity: a hostile tone only counts on a negative score, a friendly one only on a non-negative score
    if r.tone ~= nil and M.badTone[r.tone] and (r.d or 0) >= 0 then r.tone = nil end
    if r.tone ~= nil and not M.badTone[r.tone] and (r.d or 0) < 0 then r.tone = nil end
    if act ~= nil then
        local valid = false
        for _, id in ipairs(M.availableActs(listener, player)) do if id == act then valid = true end end
        if not valid or not M.actAsked(act, p.text) then act = nil end
        -- after a rude line only the player's own orders may run (never "walk with me" or favours)
        if act ~= nil and ((r.d or 0) < 0 or M.badTone[r.tone or ""]) and act ~= "HANDS_UP" and act ~= "DROP_WEAPON"
                and act ~= "DEMAND_ITEMS" then act = nil end
    end

    if act ~= nil then
        said = M.dispatch(act, player, listener, p.text, now, r)
        if said == nil then act = nil end -- A-Life declined the action: the AI's line is spoken below instead
    end
    if act == nil then
        -- A-Life's own social rules for lines that carry social weight
        local sIntent = nil
        local rows = pa.TalkSocialRows
        if p.intent ~= nil and fn(rows, "category") and M.socialCats[rows.category(p.intent)] then sIntent = p.intent
        elseif r.tone ~= nil then sIntent = r.tone end
        local verdict = nil
        -- insults / threats / "go away": A-Life's TalkSocial.ask would speak its own annoyed or ending line
        -- (Social.line) and the AI's answer would be lost. The opinion hit still goes through A-Life's
        -- NpcOpinion.adjust below (human-scaled), and real insults/threats still climb A-Life's Talk.escalate ladder.
        local negative = (sIntent ~= nil and M.badTone[sIntent]) or (r.d or 0) < 0
        if sIntent ~= nil and fn(social, "ask") and not negative then
            verdict = social.ask(player, listener, sIntent, "typed")
        end
        if type(verdict) == "table" and verdict.action ~= "go" then
            -- A-Life spoke its own annoyed / ending / refusing line (TalkSocial.line); respect it
            if verdict.close then talk.releaseHold(record.uid, p.playerKey) end
            said = verdict.text
            -- they stopped listening, but a real insult or threat still lands (human-scaled, then the ladder)
            if r.d <= M.settings.escalateAt or sIntent == "INSULT" or sIntent == "THREATEN" then
                local value = fn(opinion, "valueOf") and (opinion.valueOf(record, player) or 0) or 0
                local extra = M.humanDelta(mem, math.min(r.d, -1), value, tonumber(verdict.delta) or 0, now, sIntent)
                if extra < 0 and fn(opinion, "adjust") then
                    opinion.adjust(record, player, extra, M.why[sIntent or ""] or "You were rude to them.")
                    log("opinion " .. tostring(value) .. " + human-scale " .. tostring(extra) .. " (they had stopped talking)")
                end
                M.escalate(record, shell, player, stance, 1, tostring(sIntent or ("d " .. tostring(r.d))))
            end
        else
            if r.text ~= "" and type(M.replyGuard) == "function" then
                local okG, t = pcall(M.replyGuard, p, r.text)
                if okG and type(t) == "string" and t ~= "" then r.text = t end
            end
            if r.text ~= "" then
                M.say(shell, player, r.text)
                said = r.text
                if r.suggest and M.noteSuggest then pcall(M.noteSuggest, record.uid, r.suggest, now) end -- 0.8.3 step 3
                if r.ask and M.noteAsk then pcall(M.noteAsk, record, shell, player, r.text, now) end -- 0.8.3 step 4
                if r.gesture and M.applyGesture then pcall(M.applyGesture, shell, player, r.text, r.gesture) end -- 0.8.3 step 7
                if r.cmd and M.onAiCmd then pcall(M.onAiCmd, player, record.uid, r.cmd, r.cmdItem) end -- 0.8.2 part 2
                if r.want and M.noteWant then pcall(M.noteWant, record, player, r.want, r.text) end -- 0.8.3 step 10
                if M.maybeRob then pcall(M.maybeRob, record, player, r.text, stance) end -- v0.3.3 (patch only)
            end
            local applied = type(verdict) == "table" and tonumber(verdict.delta) or 0
            local value = 0
            if fn(opinion, "valueOf") then value = opinion.valueOf(record, player) or 0 end
            local extra = M.humanDelta(mem, r.d, value, applied, now, sIntent)
            if extra ~= 0 and fn(opinion, "adjust") and (not fn(opinion, "enabled") or opinion.enabled()) then
                local why = M.why[sIntent or ""] or (extra < 0 and "You were rude to them." or "You were easy to talk to.")
                opinion.adjust(record, player, extra, why)
                if r.d <= M.settings.spreadAt and fn(opinion, "spreadTo") then
                    pcall(opinion.spreadTo, record, player, extra, why, false)
                end
                log("opinion " .. tostring(value) .. " + A-Life " .. tostring(applied) .. " + human-scale " .. tostring(extra))
            end
            -- A-Life's hostility ladder (Talk.escalate) for real insults / threats, a moment after the reply
            if sIntent == "INSULT" or sIntent == "THREATEN" or r.d <= M.settings.escalateAt then
                M.escalate(record, shell, player, stance, 1, tostring(sIntent or ("d " .. tostring(r.d))))
            end
            -- the NPC introduced itself in its own words -> A-Life's introduction flag
            if said ~= nil and type(record.memory) == "table" and fn(names, "knows") and fn(names, "markIntroduced")
                    and not names.knows(record, p.playerKey) and stance ~= "hostile" then
                local first = record.memory.personFirst
                if type(first) == "string" and #first > 1 and string.find(string.lower(said), string.lower(first), 1, true) then
                    talk.writeMemory(record.uid, function(m) names.markIntroduced(m, p.playerKey) end)
                end
            end
            -- walk away: natural goodbye, the AI chose to leave, or they now hate you
            local after = value + applied + extra
            -- v0.3.1: the AI's "leave" only counts after a rude line, a goodbye, or when they really dislike you
            local leave = r.leave and ((r.d or 0) < 0 or after <= -40)
            if leave or sIntent == "FAREWELL" or sIntent == "GO_AWAY" or after <= M.settings.hatesAt then
                talk.releaseHold(record.uid, p.playerKey)
                -- 0.8.3 step 2: the talk really ends (window closes; they walked out -> A-Life's refusal window)
                if ALifeTalkEnd and type(ALifeTalkEnd.ended) == "function" then
                    local walkedOut = leave or sIntent == "GO_AWAY" or after <= M.settings.hatesAt
                    pcall(ALifeTalkEnd.ended, player, record.uid, walkedOut, now)
                end
            else
                talk.hold(record, shell, player, now)
            end
        end
    end

    local day = 0
    pcall(function() day = getGameTime():getNightsSurvived() end)
    mem.lines[#mem.lines + 1] = { day = day, ms = now, you = string.sub(p.text, 1, 160), me = string.sub(tostring(said or ""), 1, 200) }
    while #mem.lines > M.settings.memLines do table.remove(mem.lines, 1) end
    if M.noteTalkMemory then pcall(M.noteTalkMemory, p, r, act) end
    if said ~= nil and said ~= "" and act == nil then
        M.maybeChime(player, listener, said, 0, "Them")
    end
end

----------------------------------------------------------------------------------------------------------------
-- v3.2 reactive moments: one NPC says one short line about something that just happened (a sound, a bite, a
-- grief moment, a combat bark ...). Lua describes the situation (react.what) and the style (react.style); the
-- bridge adds the NPC's whole context (relationships, grief, sounds, fight state) and the model writes the line.
----------------------------------------------------------------------------------------------------------------
M.reactAt = {}
M.reactKeyAt = {}
function M.react(mode, listener, player, react, opts)
    opts = opts or {}
    local now = nowMs()
    if not M.settings.enabled or not M.aiHere() or type(listener) ~= "table" or type(listener.record) ~= "table" then return false end
    if not M.bridgeAlive(now, player) then return false end
    local key = opts.key or (mode .. ":" .. tostring(listener.record.uid))
    if now - (M.reactKeyAt[key] or -1e12) < (opts.keyCooldownMs or 60000) then return false end
    if now - (M.reactAt[mode] or -1e12) < (opts.modeCooldownMs or 8000) then return false end
    if not opts.urgent and now - (M.lastPlayerLineAt or -1e12) < 4000 then return false end -- you are talking
    for _, q in ipairs(M.queue) do if q.mode == mode then return false end end -- one of each kind waiting at most
    M.reactKeyAt[key], M.reactAt[mode] = now, now
    M.metrics.reacts = (M.metrics.reacts or 0) + 1
    local job = { mode = mode, uid = tostring(listener.record.uid), player = player, listener = listener, react = react,
        startMs = now, depth = 0, onDone = opts.onDone, face = opts.face }
    local at = 1
    while M.queue[at] ~= nil and M.queue[at].mode == "reply" do at = at + 1 end
    if opts.urgent then
        local cur = M.pending
        if cur ~= nil and (cur.mode == "chime" or cur.mode == "banter" or cur.mode == "ambient") then M.pending = nil end
    end
    table.insert(M.queue, at, job)
    M.pump(now)
    return true
end

function M.reactRequest(job, now)
    local listener = M.refresh(job) or job.listener
    if listener == nil then return nil end
    local pa = PA()
    local stance = fn(pa.Talk, "stance") and pa.Talk.stance(listener.record, job.player) or "neutral"
    local req = M.buildRequest(job.player, listener, "", nil, stance, now)
    req.mode = job.mode
    req.react = job.react
    req.acts, req.actHints = {}, {}
    return req
end

function M.reactFinish(p, r)
    local me = M.refresh(p)
    if me ~= nil and type(r.text) == "string" and r.text ~= "" then
        local face = p.face
        if face == "player" then face = p.player end
        M.say(me.shell, face, r.text, { record = me.record, combat = p.mode == "taunt" }) -- v0.3.3: never lost mid-fight
        if M.dlgFromReact then pcall(M.dlgFromReact, p, r.text) end -- 0.5.2.10: react.dlg = { to = uid, kind } (to another NPC)
    end
    if type(p.onDone) == "function" then pcall(p.onDone, p, r, me) end
end

for _, mode in ipairs({ "sound", "grief", "injury", "taunt", "news", "follow", "warn", "nemesis", "order", "last_words", "activity" }) do -- 0.5.1: warn / nemesis / order were never registered (fell into the chime path)
    M.eventModes[mode] = { request = M.reactRequest, finish = M.reactFinish }
end

----------------------------------------------------------------------------------------------------------------
-- NPCs reacting to each other
----------------------------------------------------------------------------------------------------------------
-- after NPC 'from' said 'line' (to the player or to another NPC), maybe one nearby NPC chimes in
function M.maybeChime(player, from, line, depth, lineTo)
    local s, pa = M.settings, PA()
    local talk = pa.Talk
    local now = nowMs()
    if depth >= s.maxChain or type(line) ~= "string" or line == "" or not fn(talk, "listeners") then return false end
    if depth == 0 and now - M.lastChainAt < s.chainCooldownMs then return false end
    if roll(100) >= (depth == 0 and s.chimeChance or s.backChance) then return false end
    local radius = type(talk.settings) == "table" and talk.settings.listenRadius or 12
    local best, bestSide = nil, false
    for _, l in ipairs(talk.listeners(player, radius)) do
        local uid = tostring(l.record.uid)
        if uid ~= tostring(from.record.uid) and not talk.busy(l.record, now) and talk.stance(l.record, player) ~= "hostile"
                and type(l.record.memory) == "table" and type(l.record.memory.person) ~= "table" then
            local hostile, side = false, false
            if fn(pa.Relations, "status") then
                local ok, st = pcall(pa.Relations.status, l.record, from.record)
                hostile = ok and st == "hostile"
            end
            if fn(pa.Relations, "sameSide") then side = pa.Relations.sameSide(l.record, from.record) == true end
            local ax, ay = pos(l.shell)
            local bx, by = pos(from.shell)
            local close = ax ~= nil and bx ~= nil and (ax - bx) ^ 2 + (ay - by) ^ 2 <= s.chimeReachTiles ^ 2
            if close and not hostile and (best == nil or (side and not bestSide)) then best, bestSide = l, side end
        end
    end
    if best == nil then return false end
    if depth == 0 then M.lastChainAt = now end
    M.submit({ mode = "chime", uid = tostring(best.record.uid), player = player, listener = best, line = line,
        speakerUid = tostring(from.record.uid), lineTo = lineTo, depth = depth + 1, startMs = now })
    return true
end

function M.finishChime(job, r)
    local pa = PA()
    local talk, speech = pa.Talk, pa.Speech
    if job.gen ~= nil and job.gen ~= M.chatGen then return end
    local me = M.refresh(job)
    if me == nil or talk.busy(me.record, nowMs()) then return end
    local text = r.text or ""
    if text == "" then
        M.metrics.quiet = M.metrics.quiet + 1 -- the model chose to stay quiet
        return
    end
    local speakerShell = job.speakerUid and fn(talk, "shellFor") and talk.shellFor(job.speakerUid) or nil
    -- leave a beat after the previous line so bubbles don't pile up
    local wait = M.settings.chimeGapMs - (nowMs() - (M.lastNpcLineAt or -1e12))
    if wait > 50 and fn(talk, "later") and not job.delayed then
        job.delayed = true
        -- Talk.later runs from A-Life's own Talk.tick (ALifeRuntime scheduler)
        if talk.later(wait, function()
            if job.gen ~= M.chatGen then return end -- you spoke in the meantime: drop it
            M.chimeHold = nil
            safe(M.finishChime, job, r)
        end) then
            M.chimeHold = nowMs() + wait + 3000
            return
        end
    end
    M.chimeHold = nil
    M.ownSay(me.shell, text, { face = speakerShell or job.player }) -- 0.5.2.3: ours (never 'foreign'), markup stripped
    M.metrics.chimes = M.metrics.chimes + 1
    if M.notePairLine and job.speakerUid ~= nil and job.lineTo ~= "you" then pcall(M.notePairLine, job, text, r) end -- 0.5.1
    if M.dlgFromChime then pcall(M.dlgFromChime, job, text, r) end -- 0.5.2.10: Interactions shows what NPCs said to each other
    -- the one who was chimed at may answer back (bounded by maxChain)
    local backChance = job.mode == "ambient" and (M.settings.ambientReplyChance or 0) or M.settings.backChance
    if job.mode == "ambient" and M.noteAmbientLine then pcall(M.noteAmbientLine, job, text, r) end
    if job.speakerUid ~= nil and job.depth < M.settings.maxChain and roll(100) < backChance then
        local reg = pa.ActorRegistry
        local rec = fn(reg, "read") and reg.read(job.speakerUid) or nil
        if rec ~= nil and speakerShell ~= nil and not talk.busy(rec, nowMs()) then
            M.submit({ mode = job.mode == "ambient" and "chime" or job.mode, uid = job.speakerUid, player = job.player,
                listener = { record = rec, shell = speakerShell }, line = text, speakerUid = job.uid,
                lineTo = "you", depth = job.depth + 1, startMs = nowMs() })
        end
    end
end

-- A-Life banter (ProjectALife.ChatterDirector.finish): when a scripted scene ends naturally near you, one member
-- may add one live line about what was just said (the scene's lines are already in M.heard), maybe one reply
function M.onSceneFinished(scene)
    local s = M.settings
    local now = nowMs()
    if not s.enabled or not M.worldHere() or M.pending ~= nil or #M.queue > 0 then return end
    if now - M.lastBanterAt < s.banterCooldownMs then return end
    if type(scene) ~= "table" or type(scene.members) ~= "table" or #scene.members < 2 then return end
    -- pre-1.0 MP (P2b): the player nearest the scene (single player: you), and that player's AI
    local fx, fy = pos(scene.members[1].shell)
    local player = nil
    if type(ALifeSide) == "table" then player = ALifeSide.nearest(fx, fy, s.banterPlayerTiles)
    else player = type(getSpecificPlayer) == "function" and getSpecificPlayer(0) or nil end
    if player == nil or not M.bridgeAlive(now, player) then return end
    local px, py = pos(player)
    if px == nil or fx == nil or (px - fx) ^ 2 + (py - fy) ^ 2 > s.banterPlayerTiles ^ 2 then return end
    local inScene = {}
    for _, m in ipairs(scene.members) do inScene[tostring(m.uid)] = m end
    local last = nil
    for i = #M.heard, 1, -1 do
        local h = M.heard[i]
        if h.uid ~= nil and inScene[h.uid] ~= nil and now - h.at < 30000 then last = h; break end
    end
    if last == nil or roll(100) >= s.banterChance then return end
    local candidates = {}
    for _, m in ipairs(scene.members) do
        if tostring(m.uid) ~= last.uid and m.shell ~= nil then candidates[#candidates + 1] = m end
    end
    local pick = candidates[roll(#candidates) + 1]
    if pick == nil then return end
    local reg = PA().ActorRegistry
    local rec = fn(reg, "read") and reg.read(tostring(pick.uid)) or nil
    if rec == nil then return end
    M.lastBanterAt = now
    M.metrics.banter = M.metrics.banter + 1
    M.submit({ mode = "banter", uid = tostring(pick.uid), player = player, listener = { record = rec, shell = pick.shell },
        line = last.text, speakerUid = last.uid, lineTo = "the group", depth = 1, startMs = now })
end

----------------------------------------------------------------------------------------------------------------
-- Chat input. Primary path needs nothing from us: A-Life itself routes the in-game chat box to its talk system:
--   * vanilla chat box present (ISChat.instance): ALifeTalkInput.lua Input.wrapChat wraps processSayMessage /
--     processShoutMessage -> Input.say -> Talk.onPlayerText -> Talk.respond (our wrapper)
--   * no vanilla chat in SP: the chat key opens A-Life's own one-line chat box (Input.onKeyPressed) -> same path
-- Safety net only if A-Life did NOT manage to wrap the chat (Input.chatWrapped ~= true) but a chat box exists:
-- wrap the chat box's submit callback and hand non-command lines to A-Life's own Input.say.
----------------------------------------------------------------------------------------------------------------
function M.chatPath()
    local input = PA() and PA().TalkInput or nil
    local vanilla = type(ISChat) == "table" and ISChat.instance ~= nil
    if vanilla and type(input) == "table" and input.chatWrapped == true then return "vanilla chat box (A-Life processSayMessage hook)" end
    if vanilla and M.chatFallback then return "vanilla chat box (ALifeTalk safety-net hook)" end
    if vanilla then return "vanilla chat box present but not hooked yet" end
    return "A-Life chat line (press your chat key)"
end

function M.installChatFallback()
    local pa = PA()
    local input = pa and pa.TalkInput or nil
    if M.chatFallback or type(input) ~= "table" or not fn(input, "say") or input.chatWrapped == true then return end
    if type(ISChat) ~= "table" or ISChat.instance == nil then return end
    local entry = ISChat.instance.textEntry
    if type(entry) ~= "table" or type(entry.onCommandEntered) ~= "function" then return end
    local original = entry.onCommandEntered
    entry.onCommandEntered = function(...)
        local text = nil
        pcall(function() text = entry:getText() end)
        local result = original(...)
        if type(text) == "string" and not string.match(text, "^%s*/") and input.chatWrapped ~= true then
            pcall(input.say, text, false) -- A-Life's own entry point ("!" = shout)
        end
        return result
    end
    M.chatFallback = true
    log("chat safety-net hook installed on ISChat.instance.textEntry.onCommandEntered")
end

-- Right-click fallback: no window. Picks that NPC as the addressee for 30 s and opens the chat line.
function M.openChat()
    if type(ISChat) == "table" and ISChat.instance ~= nil and type(ISChat.instance.focus) == "function" then
        pcall(ISChat.instance.focus, ISChat.instance)
        return
    end
    local input = PA() and PA().TalkInput or nil
    if fn(input, "open") then pcall(input.open) end
end

function M.onTalkOption(uid, name)
    M.lock = { uid = uid, untilMs = nowMs() + M.settings.targetLockMs }
    M.openChat()
end

function M.onFillMenu(playerNum, context, worldobjects, test)
    if test == true or not M.settings.enabled or type(context) ~= "table" or type(context.addOption) ~= "function" then return end
    local pa = PA()
    local talk = pa and pa.Talk or nil
    if not fn(talk, "listeners") then return end
    local player = getSpecificPlayer(playerNum)
    if player == nil then return end
    local list = talk.listeners(player, 6)
    local l = list[1]
    if l == nil then return end
    local name = nil
    if fn(pa.Names, "shown") and fn(pa.Speech, "playerKey") then name = pa.Names.shown(l.record, pa.Speech.playerKey(player)) end
    M.menuOpt(context, "talk", "A-Life: Talk to " .. tostring(name or "them") .. " (type in chat)", tostring(l.record.uid),
        M.onTalkOption, name)
    if M.addGiftMenu then pcall(M.addGiftMenu, context, player, l, name) end
    if M.addFollowMenu then pcall(M.addFollowMenu, context, player, l, name) end
    if M.openRelationship then
        M.menuOpt(context, "heart", "A-Life: Relationship with " .. tostring(name or "them"), tostring(l.record.uid),
            function(uid) local okR, errR = pcall(M.openRelationship, uid); if not okR then log("panel error: " .. tostring(errR)) end end)
    end
end


----------------------------------------------------------------------------------------------------------------
-- Install (once; never re-wraps, so other mods that wrap after us keep working)
----------------------------------------------------------------------------------------------------------------
-- 0.5.2.4: each wrap leaves a mark on the A-Life table it changed (table._alifeTalkHooks[name] = {orig, wrapper}).
-- A second copy of this file (another mod folder, a leftover, a Lua reload) finds the mark and reuses the original
-- instead of wrapping our own wrapper again - before, Speech.display ran our guard twice (two guard reshows).
function M.hookMark(tbl)
    local m = rawget(tbl, "_alifeTalkHooks")
    if type(m) ~= "table" then m = {}; rawset(tbl, "_alifeTalkHooks", m) end
    return m
end
function M.isOurHook(tbl, name)
    if type(tbl) ~= "table" then return false end
    local m = rawget(tbl, "_alifeTalkHooks")
    local mark = type(m) == "table" and m[name] or nil
    return type(mark) == "table" and mark.wrapper ~= nil and tbl[name] == mark.wrapper
end
function M.wrapOnce(tbl, name, make)
    if type(tbl) ~= "table" or type(tbl[name]) ~= "function" then return nil, false end
    local m = M.hookMark(tbl)
    local mark = m[name]
    if M.settings.hookOnce ~= false and type(mark) == "table" and type(mark.orig) == "function" then
        M.metrics.wrapSkipped = (M.metrics.wrapSkipped or 0) + 1
        M.wrapSkipNames = M.wrapSkipNames or {}
        M.wrapSkipNames[#M.wrapSkipNames + 1] = name
        -- still on top: swap the earlier copy's wrapper for this one around the SAME original (never a wrapper
        -- around a wrapper); if another mod wrapped over ours, the earlier wrapper stays where it is (still once)
        if tbl[name] == mark.wrapper then
            local w = make(mark.orig)
            tbl[name] = w
            mark.wrapper, mark.version = w, M.VERSION
        end
        return mark.orig, false
    end
    local orig = tbl[name]
    if ALifeLLMTalk._ours[orig] then return orig, false end -- already one of our wrappers on top: wrapping it again would loop
    local w = make(orig)
    tbl[name] = w
    m[name] = { orig = orig, wrapper = w, version = M.VERSION }
    return orig, true
end
function M.install()
    if M.installed then return true end
    local pa = PA()
    if pa == nil or not fn(pa.Talk, "respond") or not fn(pa.Speech, "say") then return false end
    M.wrapSkipNames = {}
    M.origRespond = M.wrapOnce(pa.Talk, "respond", function(orig) return M.respond end)
    M.origSay = M.wrapOnce(pa.Speech, "say", function(orig)
        return function(shell, text, options)
            -- 0.5.2.4: someone else (a leftover file, the patch, A-Life) sending a line WE showed on that NPC moments
            -- ago is not drawn a second time
            if not M.ownShowing and M.settings.speechOnce ~= false and M.spokenFind(shell, text, nowMs()) then
                M.dupDropped(shell, text, "Speech.say")
                return true
            end
            local result = M.origSay(shell, text, options)
            if result == true then pcall(M.noteNpcLine, shell, text) end
            return result
        end
    end)
    -- v0.4.2: every A-Life line is drawn by Speech.display (Speech.say) or Speech.sayLine (careful warnings, barks);
    -- both are wrapped to notice a line drawn over our reply. The original always runs first and its result is kept.
    for _, name in ipairs({ "display", "sayLine" }) do
        local hookName = name
        M.wrapOnce(pa.Speech, hookName, function(orig)
            return function(shell, text, a, b, c)
                local result = orig(shell, text, a, b, c)
                if result == true and not M.ownShowing then pcall(M.onForeignLine, shell, text, hookName) end
                return result
            end
        end)
    end
    local director = pa.ChatterDirector
    if fn(director, "finish") then
        M.origFinish = M.wrapOnce(director, "finish", function(orig)
            return function(scene, now)
                local result = M.origFinish(scene, now)
                pcall(M.onSceneFinished, scene)
                return result
            end
        end)
    end
    M.installed = true
    if #M.wrapSkipNames > 0 then
        log("hooks: " .. table.concat(M.wrapSkipNames, ", ") .. " were already wrapped by an earlier copy of A-Life Talk - reused, not wrapped again")
    end
    M.installParts()
    log("v" .. M.VERSION .. " hooked ProjectALife.Talk.respond, Speech.say" .. (M.origFinish and ", ChatterDirector.finish" or ""))
    log("ready v" .. ALifeSide.MOD_VERSION .. ": yieldBusy " .. (M.settings.yieldBusy ~= false and "on" or "off") .. " (hurt / fighting NPCs: A-Life's line wins, no forced or redrawn replies)")
    return true
end

-- pre-1.0 MP (docs/PLAN-MP.md P2): the parts of the world tick that may run on an MP server. A part not listed
-- runs in single player only (it reads "the" player, getPlayer()); a later phase lists it once it loops over players.
M.mpReady = M.mpReady or { hostile = true, hearing = true, persona = true, follow = true, injury = true, grief = true, -- P2b + P3
    radio = true, events = true, ambient = true, news = true, gift = true, nemesis = true } -- P5: loop over players
local function part(name)
    if type(ALifeSide) ~= "table" or not ALifeSide.mpServer() then return true end
    return M.mpReady[name] == true
end
M.partOn = part
function M.installParts()
    if M.installGifts and part("gift") then pcall(M.installGifts) end
    if M.installEvents and part("events") then pcall(M.installEvents) end
    if M.installRadio and part("radio") then pcall(M.installRadio) end
    if M.installHearing and part("hearing") then pcall(M.installHearing) end
    if M.installGrief and part("grief") then pcall(M.installGrief) end
end
function M.onTick()
    M.tick = M.tick + 1
    if M._keying then M._keying = false; pcall(M.fileClose) end
    local side = ALifeSide
    local world = type(side) ~= "table" or side.world()
    local ui = type(side) ~= "table" or side.ui()
    if ui then pcall(M.onTickUI) end
    if world then return M.onTickWorld() end
end
-- a screen: old-install check, opinion popups, the AI relay on an MP client (your bridge answers the server)
function M.onTickUI()
    if M.tick == 30 and M.checkOldInstall then pcall(M.checkOldInstall) end
    if M.popupTick and M.tick % 2 == 1 then pcall(M.popupTick) end
    if M.tick == 600 and M.chatPath then log("chat input: " .. M.chatPath()) end
    if type(ALifeSide) == "table" and ALifeSide.mpClient() and type(ALifeAIRelay) == "table" then
        local ok, err = pcall(ALifeAIRelay.clientTick, nowMs())
        if not ok then log("AI relay (client) error: " .. tostring(err)) end
    end
end
-- world logic: SP, or the MP server
-- each world part timed on its own ("Main:<part>") so the health report names the one that spikes
M._timed = M._timed or {}
local function timed(label, f)
    local H = ALifeHealth
    if type(f) ~= "function" or type(H) ~= "table" or type(H.wrap) ~= "function" then return f end
    local c = M._timed[label]
    if c == nil or c.f ~= f then c = { f = f, w = H.wrap("Main:" .. label, f) }; M._timed[label] = c end
    return c.w
end
function M.onTickWorld()
    if not M.installed then
        if M.tick % 120 == 1 then pcall(timed("install", M.install)) end
        return
    end
    if M.tick % 300 == 0 then
        pcall(timed("fallback", M.installChatFallback))
        timed("parts", M.installParts)()
    end
    -- v3.2 hearing / hostile talk / grief ticks (each pcall-guarded, staggered)
    if M.hearingTick and M.tick % 30 == 5 and part("hearing") then
        local okH, errH = pcall(timed("hearing", M.hearingTick))
        if not okH then log("hearing error: " .. tostring(errH)) end
    end
    if M.tick % 10 == 5 and #M.reshowQueue > 0 then pcall(timed("reshow", M.reshowTick), nowMs()) end -- world side: the queue lives with the replies
    if M.hostileTick and M.tick % 30 == 20 and part("hostile") then
        local okF, errF = pcall(timed("hostile", M.hostileTick))
        if not okF then log("combat talk error: " .. tostring(errF)) end
    end
    if M.injuryTick and M.tick % 60 == 10 and part("injury") then
        local okI, errI = pcall(timed("injury", M.injuryTick))
        if not okI then log("injury watch error: " .. tostring(errI)) end
    end
    if M.followTick and M.tick % 120 == 70 and part("follow") then
        local okW, errW = pcall(timed("follow", M.followTick))
        if not okW then log("follow error: " .. tostring(errW)) end
    end
    if M.griefTick and M.tick % 90 == 50 and part("grief") then
        local okG2, errG2 = pcall(timed("grief", M.griefTick))
        if not okG2 then log("grief error: " .. tostring(errG2)) end
    end
    if M.radioTick and M.tick % 30 == 15 and part("radio") then
        local okR, errR = pcall(timed("radio", M.radioTick))
        if not okR then log("radio error: " .. tostring(errR)) end
    end
    if M.scanEvents and M.tick % 60 == 45 and part("events") then
        local okE, errE = pcall(timed("events", M.scanEvents))
        if not okE then log("event scan error: " .. tostring(errE)) end
    end
    if M.ambientTick and M.tick % 60 == 30 and part("ambient") then
        local okA, errA = pcall(timed("ambient", M.ambientTick))
        if not okA then log("ambient error: " .. tostring(errA)) end
    end
    if M.giftTick and M.tick % 60 == 0 and part("gift") then
        local okG, errG = pcall(timed("gift", M.giftTick))
        if not okG then log("gift watch error: " .. tostring(errG)) end
    end
    if M.personaTick and M.tick % 90 == 40 and part("persona") then pcall(timed("persona", M.personaTick)) end -- v0.4.0 opinion hook + bridge pushes
    if M.nemesisTick and M.tick % 300 == 150 and part("nemesis") then
        local okN, errN = pcall(timed("nemesis", M.nemesisTick))
        if not okN then log("nemesis error: " .. tostring(errN)) end
    end
    if M.newsTick and M.tick % 600 == 333 and part("news") then
        local okW, errW = pcall(timed("news", M.newsTick))
        if not okW then log("news error: " .. tostring(errW)) end
    end
    local pt = M.settings.pollTicks
    if M.settings.fastReplyPoll ~= false and M.pending ~= nil and (M.pending.mode == "reply" or M.pending.mode == "radio") then pt = 1 end
    if (M.pending ~= nil or #M.queue > 0 or M.late ~= nil) and M.tick % pt == 0 then
        local ok, err = pcall(timed("poll", M.poll))
        if not ok then
            M.pending = nil
            log("poll error: " .. tostring(err))
        end
    end
end

-- v0.4.0: leftovers of the old v0.1 "ALifeTalk" add-on (media/lua/client/ALifeTalk/ALifeTalk_Core.lua and
-- ALifeTalk_Window.lua) still load when a newer zip was unpacked over an old install. They share our request/reply
-- file names and add a second context-menu entry, so we switch them off and say which files to delete.
M.OLD_FILES = { "ALifeTalk/42/media/lua/client/ALifeTalk/ALifeTalk_Core.lua", "ALifeTalk/42/media/lua/client/ALifeTalk/ALifeTalk_Window.lua" }
function M.checkOldInstall()
    local old = type(ALifeTalk) == "table" and ALifeTalk or nil
    if old == nil or M.oldWarned then return false end
    if tostring(old.VERSION or "") == "" and not old.REQ_FILE then return false end
    M.oldWarned = true
    log("WARNING: an old A-Life Talk v" .. tostring(old.VERSION or "0.1") .. " is still loading next to v" .. M.VERSION
        .. ". Delete these leftovers from your mods folder (Zomboid/mods or the Workshop folder): "
        .. table.concat(M.OLD_FILES, ", ") .. " (the whole folder media/lua/client/ALifeTalk/). They are switched off for this session.")
    pcall(function()
        if Events.OnTick and old.onTick then ALifeHealth.tickRemove(old.onTick) end
        if Events.OnFillWorldObjectContextMenu and old.onFillMenu then Events.OnFillWorldObjectContextMenu.Remove(old.onFillMenu) end
        if Events.OnGameStart and old.onGameStart then Events.OnGameStart.Remove(old.onGameStart) end
        old.pending = nil
    end)
    -- 0.5.2.4: v0.1.0 hooks nothing in A-Life (no Speech.say, no chat - checked against its source); it only had its
    -- own OnTick reply poll (same reply file as ours), its menu entry and its window. Besides removing the listeners,
    -- the functions those listeners look up by name are made inert, so even a listener we could not remove draws nothing.
    pcall(function()
        local noop = function() return nil end
        old.overhead, old.finish, old.send, old.openFor = noop, noop, noop, noop
        old.findNearbyNPCs = function() return {} end
        old.POLL_TICKS = 1e9
        old._switchedOff = M.VERSION
        if type(ALifeTalkWindow) == "table" then ALifeTalkWindow.open = noop end
    end)
    return true
end

function M.onGameStart()
    if M._keying then M._keying = false; pcall(M.fileClose) end -- every file has loaded by now
    pcall(M.checkOldInstall)
    M.heard, M.pending, M.queue = {}, nil, {}
    if M.loadSettingsFile then pcall(M.loadSettingsFile) end -- MP server: the server's own Zomboid/Lua settings file
    if type(ALifeSide) == "table" and not ALifeSide.world() then return end -- MP client: no NPCs here to hook
    pcall(M.install)
    if not M.installed then log("Project A-Life talk system not found yet; will keep checking") end
end

if type(Events) == "table" then
    if Events.OnGameStart then Events.OnGameStart.Add(M.onGameStart) end
    -- pre-1.0: a server never fires OnGameStart (42.21 jar: GameServer fires OnGameBoot + OnServerStarted)
    if type(ALifeSide) == "table" and ALifeSide.mpServer() and Events.OnServerStarted then Events.OnServerStarted.Add(M.onGameStart) end
    if Events.OnTick then ALifeHealth.add(Events.OnTick, "ALifeLLMTalk_Main", M.onTick) end
    if Events.OnFillWorldObjectContextMenu then
        ALifeRadial.addFiller("talk", "npc", function(...) pcall(M.onFillMenu, ...) end)   -- 0.5.11: radial registry
    end
end

-- 0.5.2.11: soft classifier for weaker models (safe if file missing)
pcall(function()
    require "ALifeLLMTalk/ALifeLLMTalk_Classify"
end)

return M
