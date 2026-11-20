-- A-Life NPC Overhaul: the game tells you what's wrong with the AI / voice helper.
-- Reads Zomboid\Lua\alifeai_status.txt (written by the helper every 5 s). Shows a halo note when something changes
-- and a small line in the top-left corner while something is broken. Silent when all is well,
-- and silent when the helper simply isn't running (the AI is optional).

local TAG = "[ALifeStatus]"
ALifeStatus = ALifeStatus or {}
local S = ALifeStatus
S.CHECK_MS, S.STALE_MS, S.GRACE_MS = 5000, 20000, 45000
S.msg, S.last, S.checkedAt, S.startedAt = nil, nil, 0, nil

local function nowMs() return getTimestampMs and getTimestampMs() or 0 end

function S.read()
    local r = getFileReader("alifeai_status.txt", false)
    if r == nil then return nil end
    local t = {}
    local line = r:readLine()
    while line ~= nil do
        local k, v = string.match(line, "^([%w_]+)=(.*)$")
        if k then t[k] = v end
        line = r:readLine()
    end
    r:close()
    return t
end

-- the one problem worth telling you about, or nil
function S.problem(st)
    -- AI is optional: helper not running (never set up, or turned off) is a normal state, not a problem. Stay quiet.
    if st == nil or tonumber(st.t) == nil or math.abs(nowMs() - tonumber(st.t)) > S.STALE_MS then
        return nil
    end
    -- 0.5.1 cloud AI (Zomboid\Lua\alifeai_cloud.txt)
    if st.ollama == "cloud" then
        local c = st.cloud
        if c == "badkey" then return "A-Life NPC Overhaul: the cloud AI key was rejected. Check key= in Zomboid\\Lua\\alifeai_cloud.txt." end
        if c == "nomodel" then return "A-Life NPC Overhaul: cloud AI model not found. Check model= in Zomboid\\Lua\\alifeai_cloud.txt." end
        if c == "credits" then return "A-Life NPC Overhaul: your cloud AI account is out of credits. NPCs use A-Life's own lines." end
        if c == "unreachable" then return "A-Life NPC Overhaul: can't reach the cloud AI (internet or url=). NPCs use A-Life's own lines." end
        if c == "ratelimit" then return "A-Life NPC Overhaul: the cloud AI provider is rate-limiting you. Some lines fall back to A-Life's own." end
        if c == "cap" then return "A-Life NPC Overhaul: hourly cloud AI limit reached (max_per_hour). A-Life's own lines until the hour rolls over." end
    end
    if st.ollama == "missing" then return "A-Life NPC Overhaul: Ollama isn't installed. Run Setup.cmd in the mod's bridge folder." end
    if st.ollama == "starting" then return "A-Life NPC Overhaul: starting Ollama..." end
    if st.model == "downloading" then
        return "A-Life NPC Overhaul: downloading the AI model from model.txt (one time, a few minutes). Chat starts when it finishes."
    end
    if st.model == "missing" then return "A-Life NPC Overhaul: AI model not downloaded. Run Setup.cmd again." end
    if st.bridge == "failed" or st.bridge == "stuck" then
        return "A-Life NPC Overhaul: AI bridge " .. st.bridge .. ". " .. string.sub(st.bridge_error or "", 1, 120)
    end
    if st.talk == "installing" then
        return "A-Life NPC Overhaul: installing Python for the chat engine (one time, a minute or two). Free chat starts when it finishes."
    end
    if st.talk == "nopython" then
        return "A-Life NPC Overhaul: Python is missing, so free chat is off. Run Setup.cmd again (it installs Python), then restart the game."
    end
    if st.talk == "failed" then
        return "A-Life NPC Overhaul: the chat engine (part of the AI helper) failed. " .. string.sub(st.talk_error or "", 1, 120)
    end
    if st.voice == "failed" then
        return "A-Life NPC Overhaul: voice failed (typing still works). " .. string.sub(st.voice_error or "", 1, 120)
    end
    if st.bridge == "starting" then return "A-Life NPC Overhaul: warming up the AI..." end
    return nil
end

function S.tick()
    local t = nowMs()
    if t - S.checkedAt < S.CHECK_MS then return end
    S.checkedAt = t
    S.startedAt = S.startedAt or t
    local ok, st = pcall(S.read)
    -- 0.8.11.2: your model didn't load in time and the helper switched to the fallback model (model.txt fallback=)
    if ok and type(st) == "table" and st.fallback and st.fallback ~= "" and st.fallback_at ~= S.fallbackSaid then
        S.fallbackSaid = st.fallback_at
        local player = getPlayer and getPlayer()
        local text = "A-Life NPC Overhaul: your AI model (" .. tostring(st.fallback_from) .. ") didn't load in time, so NPCs use "
            .. tostring(st.fallback) .. " for now. Why: Zomboid\\Lua\\alifeai_bridge_log.txt. It tries yours again next game."
        if player then pcall(ALifeLetter, player, text, 242, 200, 120) end
        print(TAG .. " model fallback: " .. tostring(st.fallback_from) .. " -> " .. tostring(st.fallback))
    end
    local p = S.problem(ok and st or nil)
    -- give the helper time to start with the game before complaining
    if p ~= nil and t - S.startedAt < S.GRACE_MS then return end
    -- never set up the AI (no status file at all): one note, no corner nag; typing still works without it
    S.msg = (ok and st ~= nil) and p or nil
    -- the first time this session the helper is up and healthy: say so once (how players know the AI works)
    local fresh = ok and st ~= nil and tonumber(st.t) ~= nil and math.abs(t - tonumber(st.t)) <= S.STALE_MS
    if p == nil and fresh and not S.saidReady then
        S.saidReady = true
        S.last = nil
        local player = getPlayer and getPlayer()
        local how = (ok and st and st.ollama == "cloud") and "AI connected (cloud)." or "AI connected."
        if player then pcall(function() player:setHaloNote("A-Life NPC Overhaul: " .. how .. " People answer in their own words.", 120, 255, 120, 400) end) end
        print(TAG .. " AI ready")
        return
    end
    if p ~= S.last then
        local player = getPlayer and getPlayer()
        if player then
            if p then pcall(ALifeLetter, player, p, 255, 120, 80, true)
            elseif S.last and S.saidReady then pcall(function() player:setHaloNote("A-Life NPC Overhaul: AI and voice ready", 120, 255, 120, 300) end) end
        end
        print(TAG .. " " .. tostring(p or "all ok"))
        S.last = p
    end
end

function S.draw()
    if S.msg == nil then return end
    local tm = getTextManager()
    if tm then tm:DrawString(UIFont.Small, 12, 12, S.msg, 1.0, 0.55, 0.4, 1.0) end
end

if Events ~= nil then
    if Events.OnTick then ALifeHealth.add(Events.OnTick, "ALifeStatus", function() pcall(S.tick) end) end
    if Events.OnPostUIDraw then ALifeHealth.add(Events.OnPostUIDraw, "ALifeStatus", function() pcall(S.draw) end) end
end
print(TAG .. " loaded")
