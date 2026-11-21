-- A-Life NPC Overhaul 0.8.3 step 9: GROUP TALK. Talking to one person with their people around:
--   * others nearby already chime in (Main.lua M.maybeChime, chimeChance) - now what they say becomes part of YOUR
--     talk with that person (the visit thread shows "Sam (with you): ..."), so everyone answers with all of it;
--   * talk to all of them ("you all", "everyone", "guys", "y'all", "you two/three") and someone else is much more
--     likely to chime in (groupChime instead of chimeChance) for that line;
--   * with the talk window open, their lines show in the window too, under their own name (A-Life's W:append).
-- Off: talkGroup (chime-ins work as before, outside the thread).
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalk_Group") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"

ALifeGroupTalk = ALifeGroupTalk or {}
local K = ALifeGroupTalk
K.VERSION = ALifeSide.MOD_VERSION
K.DEFAULTS = { talkGroup = true, groupChime = 90 }
K.WORDS = { "you all", "y'all", "yall", "everyone", "everybody", "guys", "you guys", "you two", "you three", "all of you",
    "folks", "you people" }
K.chimes = K.chimes or {} -- [chimer uid] = { from = uid talked to, player, at }
K.metrics = K.metrics or { boosted = 0, joined = 0 }

local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function nowMs() local n = 0; pcall(function() n = getTimestampMs() end); return n end
local function M() return ALifeLLMTalk end
local function setting(key)
    local m = M()
    local v = nil -- explicit nil checks: `a and t[key] or nil` turns a false setting into the default
    if type(m) == "table" and type(m.settings) == "table" then v = m.settings[key] end
    if v == nil then v = K.DEFAULTS[key] end
    return v
end

function K.toGroup(text)
    local low = " " .. string.lower(tostring(text or "")) .. " "
    for _, w in ipairs(K.WORDS) do
        if string.find(low, w, 1, true) then return true end
    end
    return false
end

-- the name the player knows them by (A-Life Names.knows: introduced to this player), else nil
local function knownName(record, player)
    local pa = PA()
    local mem = type(record) == "table" and type(record.memory) == "table" and record.memory or {}
    local first = mem.personFirst
    if type(first) ~= "string" or first == "" then return nil end
    local names, speech = pa and pa.Names or nil, pa and pa.Speech or nil
    if fn(names, "knows") and fn(speech, "playerKey") then
        local ok, yes = pcall(names.knows, record, speech.playerKey(player))
        if ok and yes ~= true then return nil end
    end
    return first
end

-- a line from someone who was chiming in on your talk with `from`
function K.onLine(shell, uid, text)
    if setting("talkGroup") == false or uid == nil then return end
    uid = tostring(uid)
    local c = K.chimes[uid]
    if c == nil then return end
    K.chimes[uid] = nil
    local now = nowMs()
    if now - c.at > 20000 then return end
    local m = M()
    local record = nil
    local reg = PA() and PA().ActorRegistry or nil
    if fn(reg, "read") then local ok, r = pcall(reg.read, uid); if ok then record = r end end
    local name = knownName(record, c.player) or "another of them"
    if fn(m, "visitOther") then pcall(m.visitOther, c.from, c.player, name, text, now) end
    K.metrics.joined = K.metrics.joined + 1
    -- the open talk window shows it under their name
    local W = ALifeWindowTalk
    if fn(W, "window") then
        local ok, win = pcall(W.window)
        if ok and win ~= nil and tostring(win.uid) == c.from and fn(win, "append") then pcall(win.append, win, text, name) end
    end
end

-- load time: settings, hooks into Main
do
    local m = M()
    if type(m) == "table" and type(m.settings) == "table" then
        for k, v in pairs(K.DEFAULTS) do if m.settings[k] == nil then m.settings[k] = v end end
        if type(m.fileKeys) == "table" then
            for _, key in ipairs({ "talkGroup", "groupChime" }) do
                local have = false
                for _, x in ipairs(m.fileKeys) do if x == key then have = true end end
                if not have then m.fileKeys[#m.fileKeys + 1] = key end
            end
        end
        -- "you all ...": the next chime-in after this line is far more likely
        if type(m.requestExtras) == "table" then
            table.insert(m.requestExtras, function(req, player, listener, now)
                if setting("talkGroup") ~= false and type(req.said) == "string" and K.toGroup(req.said) then
                    K.boostUntil = now + 30000
                    req.toGroup = true
                end
            end)
        end
        if fn(m, "maybeChime") and m.maybeChime__Group == nil then
            local orig = m.maybeChime
            m.maybeChime__Group = orig
            m.maybeChime = function(player, from, line, depth, lineTo)
                local s = m.settings
                local boosted = depth == 0 and setting("talkGroup") ~= false and nowMs() < (K.boostUntil or -1e12)
                local keep = s.chimeChance
                if boosted then
                    s.chimeChance = math.max(tonumber(keep) or 0, tonumber(setting("groupChime")) or 90)
                    K.boostUntil = nil
                    K.metrics.boosted = K.metrics.boosted + 1
                end
                local ok, res = pcall(orig, player, from, line, depth, lineTo)
                s.chimeChance = keep
                if not ok then error(res, 0) end
                return res
            end
        end
        -- remember who is chiming in on whose talk (Main submits a "chime" job for them)
        if fn(m, "submit") and m.submit__Group == nil then
            local orig = m.submit
            m.submit__Group = orig
            m.submit = function(job)
                if type(job) == "table" and job.mode == "chime" and job.uid ~= nil and job.speakerUid ~= nil and job.player ~= nil then
                    -- the person you're talking to: the first speaker of the chain (a chime answering a chime keeps it)
                    local root = job.speakerUid
                    local prev = K.chimes[tostring(job.speakerUid)]
                    if prev ~= nil then root = prev.from end
                    K.chimes[tostring(job.uid)] = { from = tostring(root), player = job.player, at = nowMs() }
                end
                return orig(job)
            end
        end
        if type(m.npcLineHooks) == "table" then table.insert(m.npcLineHooks, function(shell, uid, text) K.onLine(shell, uid, text) end) end
    end
end
print("[ALifeGroupTalk] ready v" .. K.VERSION .. ": group talk (others join your talk; \"you all\" brings them in)")
