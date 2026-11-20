-- A-Life NPC Overhaul 0.8.5: stand-offs, client side (the wraps live in shared/ALifeNPCOverhaul/ALifeStandoffPlus.lua).
--   * routes the "standoff" AI jobs (their voice, reading your answer) to the bridge as react mode "standoff" and back
--     to ALifeStandoffPlus.onAi; late or failed -> A-Life's own line / reading.
--   * "<their name>, stop right there / hands up / don't move": calling out someone whose name you know (server
--     decides: ALifeCmd "standoffCallOut").
--   * settings (keys listed at load, rows in Settings under "Injury, death and prisoners").
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalk_Standoff") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
-- pre-1.0 MP: no require of "ALifeLLMTalk/ALifeLLMTalk_UI" here (client-only file, loads after shared; used at call time only)
-- pre-1.0 MP: no require of "ALifeLLMTalk/ALifeLLMTalk_UIBond" here (client-only file, loads after shared; used at call time only)
require "ALifeNPCOverhaul/ALifeCmd"
require "ALifeNPCOverhaul/ALifeStandoffPlus"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Standoff"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Standoff") end end

local M = ALifeLLMTalk
if type(M) ~= "table" or type(ALifeStandoffPlus) ~= "table" then return end
local P = ALifeStandoffPlus

ALifeTalkStandoff = ALifeTalkStandoff or {}
local K = ALifeTalkStandoff
local TAG = "[ALifeTalkStandoff]"
K.VERSION = "0.8.5"
K.metrics = K.metrics or { callOuts = 0, jobs = 0, done = 0, fallback = 0 }

local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function log(msg) print(TAG .. " " .. tostring(msg)) end

function K.settings()
    if type(M.settings) ~= "table" then return end
    for k, v in pairs(P.DEFAULTS) do if M.settings[k] == nil then M.settings[k] = v end end
    if type(M.fileKeys) == "table" then
        local have = {}
        for _, k in ipairs(M.fileKeys) do have[k] = true end
        for _, k in ipairs(P.FILE_KEYS) do if not have[k] then M.fileKeys[#M.fileKeys + 1] = k; have[k] = true end end
    end
end
K.settings()
K.ROWS = {
    { "standoffPlus", "Stand-offs: lies checked, memory, your side's numbers, toll haggling, party orders, radio, calling people out (off = A-Life's own)" },
    { "standoffVoice", "Stand-offs, AI on: every line in that person's own voice (A-Life's line if the AI is slow)" },
    { "standoffVoiceMs", "Stand-offs: wait this long for the AI's line (ms)", { 1500, 2500, 4000 } },
    { "standoffTyped", "Stand-offs, AI on: the AI reads what you typed when A-Life can't" },
    { "standoffLies", "Stand-offs: lies are checked against what they see (\"just me\", \"not much\")" },
    { "standoffLieSight", "Stand-offs: your people this close give \"just me\" away (tiles)", { 10, 20, 30 } },
    { "standoffFullPack", "Stand-offs: \"not much\" is a lie when your pack is this full (%)", { 50, 70, 90 } },
    { "standoffMemory", "Stand-offs: they remember past ones with you (lies, fights, tolls paid)" },
    { "standoffJumpy", "Stand-offs: more likely to jump you per past lie or fight (%)", { 0, 25, 50, 100 } },
    { "standoffLean", "Stand-offs: extra things taken per earlier toll you paid them", { 0, 1, 2 } },
    { "standoffOdds", "Stand-offs: your side's numbers and guns change how it goes" },
    { "standoffOutnumber", "Stand-offs: your side this many times theirs and armed: they back down", { 2, 3 } },
    { "standoffTollCut", "Stand-offs: things fewer when they're outnumbered or you haggle well", { 0, 1, 2 } },
    { "standoffHaggle", "Stand-offs: chance a haggle works (%)", { 0, 25, 50, 75 } },
    { "standoffRadioSetOff", "Stand-offs: calling for backup where they can hear it sets them off" },
    { "standoffCallOut", "Call out someone whose name you know: \"Sam, hands up!\"" },
    { "standoffJoin", "Stand-offs: someone who likes you a lot may lower their gun and join" },
    { "standoffJoinOpinion", "Stand-offs: ... how much they must like you", { 40, 60, 80 } },
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
    if type(M.settingCatOf) == "table" then for _, r in ipairs(K.ROWS) do M.settingCatOf[r[1]] = "Injury, death and prisoners" end end
end
K.addRows()

-- the AI jobs: A-Life's react request, sent as mode "standoff" (bridge 0.8.5)
if type(M.eventModes) == "table" then
    M.eventModes.standoff = {
        request = function(job, now)
            if not fn(M, "reactRequest") then return nil end
            local req = M.reactRequest(job, now)
            if type(req) ~= "table" then return nil end
            req.mode = "standoff"
            req.react = job.react
            if type(job.standoff) == "table" then req.standoff = job.standoff end
            K.metrics.jobs = K.metrics.jobs + 1
            return req
        end,
        finish = function(p, r) K.metrics.done = K.metrics.done + 1; pcall(P.onAi, p.soJob, r) end,
        fallback = function(p) K.metrics.fallback = K.metrics.fallback + 1; pcall(P.onAi, p.soJob, nil) end,
    }
end

-- "<name>, hands up!": who did you name? (people near you whose name you know, by first name or full name)
function K.named(player, text)
    local pa = PA()
    local T = pa.Talk
    if not fn(T, "listeners") then return nil end
    local low = " " .. string.lower(tostring(text or "")) .. " "
    low = string.gsub(low, "[^%w%s']", " ")
    local key = nil
    if fn(pa.Speech, "playerKey") then local ok, k = pcall(pa.Speech.playerKey, player); if ok then key = k end end
    for _, l in ipairs(T.listeners(player, 25) or {}) do
        local rec = l.record
        if type(rec) == "table" then
            local knows = true
            if fn(pa.Names, "knows") then local ok, k = pcall(pa.Names.knows, rec, key); knows = ok and k == true end
            local name = fn(pa.Names, "of") and pa.Names.of(rec) or nil
            if knows and type(name) == "string" then
                local first = string.lower(string.match(name, "^(%S+)") or name)
                if #first >= 2 and string.find(low, " " .. first .. " ", 1, true) then return tostring(rec.uid) end
            end
        end
    end
    return nil
end
function K.onWords(player, text, loud, hearers)
    if P.setting("standoffCallOut") == false or not P.on() or not P.calledOut(text) then return end
    local uid = K.named(player, text)
    if uid == nil then return end
    K.metrics.callOuts = K.metrics.callOuts + 1
    ALifeCmd.send(player, "standoffCallOut", { uid = uid })
end
if type(M.playerWordHooks) == "table" and not K._words then K._words = true; table.insert(M.playerWordHooks, function(...) pcall(K.onWords, ...) end) end

function K.install()
    K.settings()
    K.addRows()
    log("ready v" .. K.VERSION .. ": stand-off AI jobs routed, call-outs " .. (P.setting("standoffCallOut") ~= false and "on" or "off"))
end
if type(Events) == "table" and Events.OnGameStart ~= nil then Events.OnGameStart.Add(function() pcall(K.install) end) end
