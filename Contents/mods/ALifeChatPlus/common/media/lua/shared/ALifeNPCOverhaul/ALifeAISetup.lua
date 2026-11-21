-- A-Life NPC Overhaul 0.8.12: AI SETUP (the logic behind the "AI" tab) + THE HELPER COMMAND CHANNEL.
-- The game can't start programs on your PC. The helper (bridge\alifeai_watcher.ps1, started by Setup.cmd / with Windows)
-- can. They talk through files in Zomboid\Lua:
--   alifeai_status.txt        helper -> game, every 5 s: helper / Ollama / model / bridges state (already there, 0.3)
--   alifeai_models.txt        helper -> game: installed models, "name|bytes" per line
--   alifeai_setup_status.txt  helper -> game: the last command's job (id, action, state, progress, result)
--   alifeai_cmd.txt           game -> helper: ONE command (id, action, arg). The helper reads it, deletes it, does it.
--                             Fixed list only (A.ACTIONS); the helper checks it again; never a shell line.
--   alifeai_setup.txt         game -> helper + both bridges: your choices (model, num_ctx, num_predict, timeout,
--                             warmup, fallback). Overrides model.txt, survives mod updates.
--   alifeai_doctor_game.txt   game -> helper: mod version + settings, folded into alifeai_doctor.txt (Doctor check)
-- Multiplayer: the AI runs on the host. Client asks "aiSetupAsk", server answers "aiSetupState" (read from the server's
-- own Zomboid\Lua). Only the host (single player, or a player with admin power) may send "aiSetupDo"; everyone else
-- gets a read-only card. Args are plain tables, checked again on the server.
require "ALifeNPCOverhaul/AA_Side"
require "ALifeNPCOverhaul/ALifeCmd"

ALifeAISetup = ALifeAISetup or {}
local A = ALifeAISetup
local TAG = "[ALifeAISetup]"
A.VERSION = ALifeSide.MOD_VERSION
A.FILES = { status = "alifeai_status.txt", models = "alifeai_models.txt", job = "alifeai_setup_status.txt",
    cmd = "alifeai_cmd.txt", setup = "alifeai_setup.txt", game = "alifeai_doctor_game.txt" }
-- the fixed action list (the helper has the same list and ignores anything else)
A.ACTIONS = { pull = "model", delete = "model", pick = "none", warm = "none", test = "none", restart = "none",
    doctor = "none", get_ollama = "none", autostart = "onoff", power = "onoff" }
-- settings (kept with the mod's settings; these are the defaults)
A.DEFAULTS = {
    aiSetupTab = true,      -- the AI tab in the A-Life window
    aiSlowMs = 8000,        -- a test reply slower than this (ms) counts as slow (tip: smaller model / smaller context)
    aiSetupStaleMs = 20000, -- helper status older than this (ms) = helper not running
    aiTestFreshMin = 60,    -- a passed test stays green this many real minutes
    aiStatusLight = true,   -- a small "AI ready / warming / slow / down" line over the talk window
    aiFirstLetter = true,   -- one letter, once, pointing new players at the AI tab (never again after)
    aiFirstLetterSec = 90,  -- real seconds into the game before that letter
}
-- advanced (the fold): what goes in alifeai_setup.txt. choices = the safe range offered in the menu.
A.ADV = {
    { key = "num_ctx", default = 4096, choices = { 2048, 4096, 6144, 8192, 12288, 16384 } },
    { key = "num_predict", default = 80, choices = { 50, 80, 120, 160, 240 } },
    { key = "timeout", default = 30, choices = { 15, 20, 30, 45, 60, 90 } },
    { key = "warmup", default = 180, choices = { 60, 120, 180, 300, 600 } },
    { key = "fallback", default = "gemma3:4b", model = true },
    -- 0.8.12: words. profile = how much the NPC is told each time (auto = by model size); ptt = the push-to-talk key
    { key = "profile", default = "auto", words = { "auto", "lite", "normal", "full" } },
    { key = "ptt", default = "CapsLock", words = { "CapsLock", "Mouse4", "Mouse5", "MiddleMouse", "RightCtrl", "RightAlt",
        "ScrollLock", "Pause", "Backtick", "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12" }, letter = true },
}
-- known-good models (same list as model.txt). gb = download size, vram = GB of video memory, speed 1 (slow) - 3 (fast)
A.KNOWN = {
    { name = "llama3.2:3b", gb = 2.0, vram = 4, speed = 3, open = false, what = "Fastest. Short, simple replies. Older or laptop GPUs." },
    { name = "qwen2.5:3b", gb = 1.9, vram = 4, speed = 3, open = false, what = "Quick, follows instructions; voice a bit flat." },
    { name = "gemma3:4b", gb = 3.3, vram = 6, speed = 2, open = false, what = "Default. Good mix of speed and character. Can be polite." },
    { name = "hf.co/HauhauCS/Gemma-4-E4B-Uncensored-HauhauCS-Aggressive:Q4_K_M", short = "Gemma 4B uncensored", gb = 5.0, vram = 7, speed = 2, open = true,
      what = "Uncensored Gemma. Raiders sound like raiders, no refusals." },
    { name = "llama3.1:8b", gb = 4.9, vram = 8, speed = 2, open = false, what = "The old default. Handles long prompts well." },
    { name = "qwen2.5:7b", gb = 4.7, vram = 8, speed = 2, open = false, what = "Best at keeping facts straight and on topic." },
    { name = "hf.co/bartowski/L3-8B-Stheno-v3.2-GGUF:Q4_K_M", short = "Stheno 8B (role-play)", gb = 4.9, vram = 8, speed = 2, open = true,
      what = "Role-play tuned. Most human, gritty and emotional; looser with facts." },
    { name = "gemma3:12b", gb = 8.1, vram = 12, speed = 1, open = false, what = "Smarter and more natural. Slower." },
    { name = "mistral-nemo", gb = 7.1, vram = 12, speed = 1, open = true, what = "Strong role-play voice, long memory. Slower." },
}

local function log(m) print(TAG .. " " .. tostring(m)) end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function nowMs() return type(getTimestampMs) == "function" and getTimestampMs() or 0 end

function A.setting(key)
    local m = ALifeLLMTalk
    local v = nil
    if type(m) == "table" and type(m.settings) == "table" then v = m.settings[key] end
    if v == nil then v = A.DEFAULTS[key] end
    return v
end
-- new keys go in the settings file list at load time (or they reset on restart). Shared loads before the client's
-- Main, so the client file (ALifeTalk_AISetup.lua) calls this at its own load time.
function A.registerSettings()
    local m = ALifeLLMTalk
    if type(m) == "table" and type(m.settings) == "table" then
        m.fileKeys = m.fileKeys or {}
        for k, v in pairs(A.DEFAULTS) do
            if m.settings[k] == nil then m.settings[k] = v end
            local have = false
            for _, x in ipairs(m.fileKeys) do if x == k then have = true end end
            if not have then m.fileKeys[#m.fileKeys + 1] = k end
        end
        return true
    end
    return false
end
A.registerSettings()

----------------------------------------------------------------------------------------------------------------
-- checks
----------------------------------------------------------------------------------------------------------------
-- an Ollama model name: letters, digits, . _ : / - only (no spaces, quotes, "..", nothing a shell could read)
function A.validModel(s)
    if type(s) ~= "string" or #s < 1 or #s > 120 then return false end
    if not string.match(s, "^[%w%._:/%-]+$") then return false end
    if string.find(s, "..", 1, true) or string.sub(s, 1, 1) == "-" or string.sub(s, 1, 1) == "/" then return false end
    return true
end
function A.advOf(key) for _, a in ipairs(A.ADV) do if a.key == key then return a end end return nil end
-- a value for an advanced key, or nil when it's not allowed
function A.cleanAdv(key, v)
    local a = A.advOf(key)
    if a == nil then return nil end
    if a.model then return A.validModel(v) and v or nil end
    if a.words then
        if type(v) ~= "string" then return nil end
        for _, w in ipairs(a.words) do if string.lower(w) == string.lower(v) then return w end end
        if a.letter and string.match(v, "^%w$") then return string.upper(v) end
        return nil
    end
    local n = tonumber(v)
    if n == nil then return nil end
    n = math.floor(n)
    local lo, hi = a.choices[1], a.choices[#a.choices]
    if n < lo or n > hi then return nil end
    return n
end
function A.knownOf(name)
    for _, k in ipairs(A.KNOWN) do if k.name == name or k.name .. ":latest" == name then return k end end
    return nil
end
-- single player: you are the host. Multiplayer: admin power (vanilla B42: getRole():hasAdminPower(); unverified on
-- the server side of 42.21, guarded: no answer = not host)
function A.isHost(player)
    local client = ALifeSide.client()
    local server = ALifeSide.server()
    if not client and not server then return true end
    if player == nil then return false end
    local ok, yes = pcall(function() return player:getRole():hasAdminPower() end)
    return ok and yes == true
end

----------------------------------------------------------------------------------------------------------------
-- files
----------------------------------------------------------------------------------------------------------------
function A.readLines(name)
    if type(getFileReader) ~= "function" then return nil end
    local ok, r = pcall(getFileReader, name, false)
    if not ok or r == nil then return nil end
    local out = {}
    pcall(function()
        local line = r:readLine()
        while line ~= nil and #out < 400 do
            line = tostring(line)
            if #out == 0 then line = string.gsub(line, "^\239\187\191", "") end -- a UTF-8 BOM (Notepad) on line 1
            out[#out + 1] = line
            line = r:readLine()
        end
    end)
    pcall(function() r:close() end)
    return out
end
function A.readKV(name)
    local lines = A.readLines(name)
    if lines == nil then return nil end
    local t = {}
    for _, l in ipairs(lines) do
        local k, v = string.match(l, "^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if k and string.sub(k, 1, 1) ~= "#" then t[k] = v end
    end
    return t
end
function A.writeLines(name, lines)
    if type(getFileWriter) ~= "function" then return false end
    local ok = pcall(function()
        local w = getFileWriter(name, true, false)
        for _, l in ipairs(lines) do w:write(tostring(l) .. "\n") end
        w:close()
    end)
    return ok
end
function A.readModels()
    local out = {}
    for _, l in ipairs(A.readLines(A.FILES.models) or {}) do
        local n, b = string.match(l, "^([^|]+)|(%d*)")
        if n and A.validModel(n) and #out < 30 then out[#out + 1] = { n = n, gb = math.floor((tonumber(b) or 0) / 1e8) / 10 } end
    end
    return out
end
-- your choices: alifeai_setup.txt (only known keys, checked)
function A.readSetup()
    local kv = A.readKV(A.FILES.setup) or {}
    local out = {}
    if A.validModel(kv.model) then out.model = kv.model end
    for _, a in ipairs(A.ADV) do
        local v = A.cleanAdv(a.key, kv[a.key])
        if v ~= nil then out[a.key] = v end
    end
    return out
end
function A.writeSetup(setup)
    local lines = { "# A-Life NPC Overhaul: AI choices from the AI tab. They win over model.txt. Delete this file to go back." }
    if type(setup) ~= "table" then return false end
    if A.validModel(setup.model) then lines[#lines + 1] = "model=" .. setup.model end
    for _, a in ipairs(A.ADV) do
        local v = A.cleanAdv(a.key, setup[a.key])
        if v ~= nil then lines[#lines + 1] = a.key .. "=" .. tostring(v) end
    end
    return A.writeLines(A.FILES.setup, lines)
end
-- a command still waiting for the helper (it deletes the file when it takes it)
function A.cmdWaiting()
    local lines = A.readLines(A.FILES.cmd)
    if lines == nil then return false end
    for _, l in ipairs(lines) do if string.match(l, "^action=%a") then return true end end
    return false
end
A.lastId = A.lastId or 0
-- a whole number as digits (Kahlua's string.format has no %.0f, and tostring of a big number can come out as 1.7E12)
function A.intStr(n)
    n = math.floor(tonumber(n) or 0)
    if n <= 0 then return "0" end
    local s = ""
    while n > 0 do local d = n % 10; s = string.char(48 + d) .. s; n = math.floor(n / 10) end
    return s
end
function A.writeCmd(action, arg)
    local id = math.max(nowMs(), A.lastId + 1)
    A.lastId = id
    local ok = A.writeLines(A.FILES.cmd, { "id=" .. A.intStr(id), "action=" .. action, "arg=" .. (arg or "") })
    return ok and id or nil
end

----------------------------------------------------------------------------------------------------------------
-- the state (what the tab shows); plain table, crosses the network
----------------------------------------------------------------------------------------------------------------
function A.state(player)
    local st = A.readKV(A.FILES.status)
    local job = A.readKV(A.FILES.job)
    local s = { host = A.isHost(player), at = nowMs(), never = st == nil }
    local t = st and tonumber(st.t) or nil
    s.helper = (t ~= nil and math.abs(nowMs() - t) <= (tonumber(A.setting("aiSetupStaleMs")) or 20000)) and "up" or "down"
    if st ~= nil then
        s.ollama, s.model, s.bridge, s.talk, s.cloud = st.ollama, st.model, st.bridge, st.talk, st.cloud
        s.modelName, s.helperVer, s.fallback = st.model_name, st.helper, st.fallback
        s.autostart = st.autostart
        s.power = st.power == "off" and "off" or "on" -- the AI switch (alifeai_off.flag): off = nothing is started
        s.bridgeErr = st.bridge_error and string.sub(st.bridge_error, 1, 160) or nil
        s.talkErr = st.talk_error and string.sub(st.talk_error, 1, 160) or nil
    end
    if job ~= nil and job.action then
        s.job = { id = job.id, action = job.action, arg = job.arg, state = job.state, progress = tonumber(job.progress) or 0,
            msg = job.msg and string.sub(job.msg, 1, 200) or nil, ms = tonumber(job.ms), loadMs = tonumber(job.load_ms),
            tps = tonumber(job.tps), gpu = tonumber(job.gpu), reply = job.reply and string.sub(job.reply, 1, 200) or nil,
            model = job.model, t = tonumber(job.t), done = tonumber(job.done_mb), total = tonumber(job.total_mb) }
    end
    if s.host then
        s.models = A.readModels()
        s.setup = A.readSetup()
        s.waiting = A.cmdWaiting()
    end
    return s
end

-- the five step cards: { id, state = ok | busy | bad | todo | skip | wait, why = code }
function A.steps(s, now)
    now = now or nowMs()
    local out = {}
    local function add(id, state, why) out[#out + 1] = { id = id, state = state, why = why } end
    local job = type(s) == "table" and s.job or nil
    local running = job ~= nil and job.state == "running"
    if type(s) ~= "table" or s.helper ~= "up" then
        add("helper", "bad", "down")
        for _, id in ipairs({ "ollama", "model", "test", "ready" }) do add(id, "wait", "helper") end
        return out
    end
    add("helper", "ok", nil)
    local cloud = s.ollama == "cloud"
    -- Ollama
    if cloud then add("ollama", "skip", "cloud")
    elseif running and job.action == "get_ollama" then add("ollama", "busy", "installing")
    elseif s.ollama == "ok" then add("ollama", "ok", nil)
    elseif s.ollama == "starting" then add("ollama", "busy", "starting")
    else add("ollama", "bad", "missing") end
    -- the model
    local ollamaOk = cloud or s.ollama == "ok"
    if cloud then add("model", "skip", "cloud")
    elseif not ollamaOk then add("model", "wait", "ollama")
    elseif running and job.action == "pull" then add("model", "busy", "pulling")
    elseif s.model == "ok" then add("model", "ok", nil)
    elseif s.model == "downloading" then add("model", "busy", "downloading")
    else add("model", "bad", "missing") end
    -- the test
    local modelOk = cloud or s.model == "ok"
    if cloud then add("test", "skip", "cloud")
    elseif not modelOk then add("test", "wait", "model")
    elseif running and (job.action == "test" or job.action == "warm") then add("test", "busy", "testing")
    elseif job ~= nil and job.action == "test" and job.state == "done" and job.model == s.modelName
        and (job.t == nil or now - job.t < (tonumber(A.setting("aiTestFreshMin")) or 60) * 60000) then
        local slow = (job.ms or 0) > (tonumber(A.setting("aiSlowMs")) or 8000) or (job.gpu ~= nil and job.gpu < 100)
        add("test", "ok", slow and "slow" or nil)
    elseif job ~= nil and job.action == "test" and job.state == "failed" then add("test", "bad", "failed")
    else add("test", "todo", nil) end
    -- ready
    if not modelOk then add("ready", "wait", "model")
    elseif s.bridge == "ok" and s.talk ~= "failed" and s.talk ~= "nopython" then add("ready", "ok", s.talk ~= "ok" and "talkStarting" or nil)
    elseif s.bridge == "failed" or s.bridge == "stuck" then add("ready", "bad", s.bridge)
    elseif s.talk == "failed" or s.talk == "nopython" then add("ready", "bad", s.talk)
    else add("ready", "busy", "warming") end
    return out
end
-- one word for other players / the talk window: ready / slow / warming / down / off (helper not running) / none
-- (never set up: no status file at all; the AI is optional, so nothing is shown then)
function A.summary(s)
    if type(s) ~= "table" or s.never then return "none" end
    if s.helper ~= "up" then return "off" end
    if s.power == "off" then return "paused" end
    local steps = A.steps(s)
    local r = steps[#steps]
    if r.state == "ok" then return steps[4].why == "slow" and "slow" or "ready" end
    if r.state == "busy" then return "warming" end
    return "down"
end

----------------------------------------------------------------------------------------------------------------
-- doing it (server side; SP = direct)
----------------------------------------------------------------------------------------------------------------
-- args: { action, arg, setup = { model, num_ctx, ... }, game = { [k] = v } }  -> ok, why
function A.run(player, args)
    if not A.isHost(player) then return false, "notHost" end
    if type(args) ~= "table" then return false, "bad" end
    local action = args.action
    local kind = type(action) == "string" and A.ACTIONS[action] or nil
    if kind == nil then return false, "badAction" end
    local arg = ""
    if kind == "model" then
        if not A.validModel(args.arg) then return false, "badModel" end
        arg = args.arg
    elseif kind == "onoff" then
        if args.arg ~= "on" and args.arg ~= "off" then return false, "bad" end
        arg = args.arg
    end
    if A.cmdWaiting() then return false, "waiting" end
    if type(args.setup) == "table" then
        if not A.writeSetup(args.setup) then return false, "write" end
    end
    -- multiplayer doctor: the client's short game part (single player writes the full one itself, on the same PC)
    if action == "doctor" and type(args.game) == "table" then
        local lines = { "A-Life NPC Overhaul (game side, from the server) " .. A.VERSION }
        do
            local keys = {}
            for k in pairs(args.game) do if type(k) == "string" then keys[#keys + 1] = k end end
            table.sort(keys)
            for _, k in ipairs(keys) do
                local v = args.game[k]
                if type(v) ~= "table" then lines[#lines + 1] = k .. "=" .. string.gsub(tostring(v), "[\r\n]", " ") end
            end
        end
        A.writeLines(A.FILES.game, lines)
    end
    local id = A.writeCmd(action, arg)
    if id == nil then return false, "write" end
    log("command " .. action .. (arg ~= "" and (" " .. arg) or "") .. " -> helper (id " .. A.intStr(id) .. ")")
    return true, nil
end

----------------------------------------------------------------------------------------------------------------
-- 0.8.12: CLOUD AI from the tab (Zomboid\Lualifeai_cloud.txt, the file "Set up cloud AI.cmd" opened in Notepad).
-- Single player only: the key is typed on this PC and written straight to this PC's file, never sent over the
-- network or logged. The tab never reads the key back: it only learns that one is saved.
----------------------------------------------------------------------------------------------------------------
A.CLOUD_FILE = "alifeai_cloud.txt"
A.PROVIDERS = {
    { name = "OpenRouter", url = "https://openrouter.ai/api/v1", what = "One key, hundreds of models, some free. Easiest start." },
    { name = "OpenAI", url = "https://api.openai.com/v1", what = "GPT models. Pay per use." },
    { name = "Groq", url = "https://api.groq.com/openai/v1", what = "Very fast replies. Free tier with limits." },
    { name = "DeepSeek", url = "https://api.deepseek.com/v1", what = "Cheap and good at role-play." },
    { name = "Mistral", url = "https://api.mistral.ai/v1", what = "Mistral's own models." },
    { name = "LM Studio (this PC)", url = "http://127.0.0.1:1234/v1", what = "A local model in LM Studio. Any key works." },
}
A.CLOUD_CAPS = { 30, 60, 100, 150, 300, 600, 1200 }
function A.validUrl(u)
    return type(u) == "string" and #u >= 10 and #u <= 200 and string.match(u, "^https?://[%w%.%-_:%[%]]+[%w%./%-_:%%~]*$") ~= nil
end
function A.validKey(k) return type(k) == "string" and #k >= 1 and #k <= 300 and string.match(k, "^[%w%-_%.:=/+]+$") ~= nil end
function A.validCloudModel(m) return type(m) == "string" and #m >= 1 and #m <= 150 and string.match(m, "^[%w%-_%.:/@+]+$") ~= nil end
-- what the tab may know: never the key
function A.readCloud()
    local kv = A.readKV(A.CLOUD_FILE)
    if kv == nil then return { exists = false } end
    local on = string.lower(tostring(kv.enabled or ""))
    return { exists = true, enabled = on == "true" or on == "yes" or on == "1" or on == "on", url = kv.url, model = kv.model,
        background = kv.background == "cloud" and "cloud" or "off", cap = tonumber(kv.max_per_hour) or 150,
        hasKey = kv.key ~= nil and kv.key ~= "" }
end
-- c = { enabled, url, key (empty = keep the saved one), model, background, cap } -> ok, why
function A.writeCloud(c)
    if type(c) ~= "table" then return false, "bad" end
    local old = A.readKV(A.CLOUD_FILE) or {}
    local key = (type(c.key) == "string" and c.key ~= "") and c.key or old.key
    if c.enabled then
        if not A.validUrl(c.url) then return false, "url" end
        if not A.validKey(key) then return false, "key" end
        if not A.validCloudModel(c.model) then return false, "model" end
    end
    if c.url ~= nil and c.url ~= "" and not A.validUrl(c.url) then return false, "url" end
    if c.key ~= nil and c.key ~= "" and not A.validKey(c.key) then return false, "key" end
    if c.model ~= nil and c.model ~= "" and not A.validCloudModel(c.model) then return false, "model" end
    local cap = math.floor(tonumber(c.cap) or tonumber(old.max_per_hour) or 150)
    if cap < 1 then cap = 1 elseif cap > 10000 then cap = 10000 end
    local lines = {
        "# A-Life NPC Overhaul - CLOUD AI. Set from the game's AI tab (or edit by hand). Never share this file: it holds your key.",
        "# Privacy: what you say to NPCs is sent to your provider. Cost: you pay your provider; max_per_hour caps it.",
        "enabled=" .. (c.enabled and "true" or "false"),
        "url=" .. tostring((c.url ~= nil and c.url ~= "") and c.url or (old.url or "")),
        "key=" .. tostring(key or ""),
        "model=" .. tostring((c.model ~= nil and c.model ~= "") and c.model or (old.model or "")),
        "background=" .. ((c.background == "cloud") and "cloud" or "off"),
        "max_per_hour=" .. cap,
    }
    local known = { enabled = true, url = true, key = true, model = true, background = true, max_per_hour = true }
    for k, v in pairs(old) do if not known[k] then lines[#lines + 1] = k .. "=" .. tostring(v) end end
    if not A.writeLines(A.CLOUD_FILE, lines) then return false, "write" end
    log("cloud AI " .. (c.enabled and "on" or "off") .. " (saved from the AI tab; key not logged)")
    return true, nil
end

if not A._cmds then
    A._cmds = true
    ALifeCmd.onServer("aiSetupAsk", function(player, args)
        ALifeCmd.reply(player, "aiSetupState", A.state(player))
    end)
    ALifeCmd.onServer("aiSetupDo", function(player, args)
        local ok, why = A.run(player, args)
        ALifeCmd.reply(player, "aiSetupDone", { ok = ok, why = why, action = type(args) == "table" and args.action or nil })
        if ok then ALifeCmd.reply(player, "aiSetupState", A.state(player)) end
    end)
    ALifeCmd.onClient("aiSetupState", function(payload) A.last = payload; A.lastAt = nowMs() end)
    ALifeCmd.onClient("aiSetupDone", function(payload)
        A.lastDone = payload
        if fn(A, "onDone") then pcall(A.onDone, payload) end
    end)
end
log("ready v" .. A.VERSION .. ": AI tab logic, helper command channel (10 fixed actions), host-only in MP")
