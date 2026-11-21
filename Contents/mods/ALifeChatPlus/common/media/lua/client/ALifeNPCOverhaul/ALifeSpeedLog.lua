-- A-Life NPC Overhaul: how fast the AI answers, measured in game (time from your line to the NPC's AI reply).
-- Writes Zomboid\Lua\alifeai_speed.txt every minute while you play: replies, average, fastest, slowest,
-- the share that took too long and fell back to A-Life's own line, and the model in use.
local TAG = "[ALifeSpeed]"
ALifeSpeedLog = ALifeSpeedLog or {}
local S = ALifeSpeedLog
S.reply = { n = 0, sum = 0, min = nil, max = 0, slow = 0 }   -- your conversations
S.chat = { n = 0, sum = 0, max = 0 }                          -- NPCs chiming in / talking among themselves
S.fallbacks = 0
S.SLOW_MS = 5000

local function now() return type(getTimestampMs) == "function" and getTimestampMs() or 0 end
local function note(bucket, ms)
    if type(ms) ~= "number" or ms < 0 or ms > 120000 then return end
    bucket.n = bucket.n + 1; bucket.sum = bucket.sum + ms
    if ms > bucket.max then bucket.max = ms end
    if bucket.min ~= nil or bucket == S.reply then
        if bucket.min == nil or ms < bucket.min then bucket.min = ms end
    end
    if bucket == S.reply and ms >= S.SLOW_MS then bucket.slow = bucket.slow + 1 end
end

local function model()
    local ok, line = pcall(function()
        local r = getFileReader("alifetalk_status.txt", false)
        if r == nil then return nil end
        local l = r:readLine(); r:close(); return l
    end)
    return ok and line and (string.match(line, "alive%s+%d+%s+(%S+)") or line) or "?"
end

function S.write()
    local r, c = S.reply, S.chat
    local avg = r.n > 0 and math.floor(r.sum / r.n) or 0
    local cavg = c.n > 0 and math.floor(c.sum / c.n) or 0
    local total = r.n + S.fallbacks
    local text = string.format(
        "model=%s\nreplies=%d avg_ms=%d fastest_ms=%d slowest_ms=%d over_5s=%d\nfell_back_to_alife=%d of %d (%d%%)\nnpc_chatter=%d avg_ms=%d slowest_ms=%d\n" ..
        "guide: under 2000 ms feels natural, 2000-5000 ok, over 5000 too slow (pick a smaller model)\n",
        tostring(model()), r.n, avg, r.min or 0, r.max, r.slow, S.fallbacks, total,
        total > 0 and math.floor(100 * S.fallbacks / total) or 0, c.n, cavg, c.max)
    pcall(function()
        local w = getFileWriter("alifeai_speed.txt", true, false)
        w:write(text); w:close()
    end)
end

function S.install()
    local M = ALifeLLMTalk
    if S.__installed or type(M) ~= "table" or type(M.finish) ~= "function" then return false end
    S.__installed = true
    local finish, chime, fallback = M.finish, M.finishChime, M.fallback
    M.finish = function(p, r, ...)
        pcall(note, S.reply, now() - (tonumber(type(p) == "table" and p.sentMs) or now()))
        return finish(p, r, ...)
    end
    if type(chime) == "function" then
        M.finishChime = function(job, r, ...)
            pcall(note, S.chat, now() - (tonumber(type(job) == "table" and job.sentMs) or now()))
            return chime(job, r, ...)
        end
    end
    if type(fallback) == "function" then
        M.fallback = function(p, ...)
            S.fallbacks = S.fallbacks + 1
            return fallback(p, ...)
        end
    end
    ALifeHealth.note(TAG, "measuring AI reply times -> Zomboid/Lua/alifeai_speed.txt")
    return true
end

if Events ~= nil then
    if Events.OnGameStart then Events.OnGameStart.Add(function() pcall(S.install) end) end
    if Events.EveryOneMinute then
        local ticks = 0
        ALifeHealth.add(Events.EveryOneMinute, "ALifeSpeedLog", function()
            if not S.__installed then pcall(S.install) end
            ticks = ticks + 1
            if ticks % 2 == 0 and (S.reply.n + S.fallbacks + S.chat.n) > 0 then pcall(S.write) end
        end)
    end
end
