-- A-Life NPC Overhaul 0.8.12: THE "AI" TAB. Set up the AI from inside the game, step by step:
--   1 helper running  2 Ollama  3 pick a model (download / delete)  4 test reply (time, graphics card)  5 AI ready
-- Advanced fold (closed): reading size, reply length, wait limit, load wait, backup model. Every button has a hover tip.
-- The tab only asks (ALifeAISetup.ask / .act); ALifeAISetup (shared) decides and talks to the helper.
-- Multiplayer: every player gets the full tab for their OWN AI (it runs on their PC; the relay sends their NPC lines
-- to the server). Never asks the server: a dedicated server has no AI (pre-1.0 fix: it showed "Host AI: none").
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("ui", "ALifeTalk_AISetup") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
require "ALifeNPCOverhaul/ALifeAISetup"
require "ALifeNPCOverhaul/ALifeBugReports"
local M = ALifeLLMTalk
local A = ALifeAISetup
if type(M) ~= "table" or type(A) ~= "table" then return end
local TAG = "[ALifeAISetupTab]"
local K = {}
M.aiSetupTab = K
K.VERSION = ALifeSide.MOD_VERSION
A.registerSettings()

local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function playerOf() local p = nil; pcall(function() p = ALifeSide.you() end); return p end
local function nowMs() return type(getTimestampMs) == "function" and getTimestampMs() or 0 end
local function tr(k, en, ...)
    if ALifeTr then return ALifeTr("IGUI_ALCP_AI_" .. k, en, ...) end
    local a = { ... }
    return (string.gsub(en, "{(%d)}", function(i) return tostring(a[tonumber(i)] or "") end))
end
local GREEN, YELLOW, RED, GREY, GOLD, TXT = " <RGB:0.45,0.85,0.45> ", " <RGB:0.95,0.8,0.35> ", " <RGB:0.92,0.45,0.35> ",
    " <RGB:0.55,0.56,0.6> ", " <RGB:0.84,0.7,0.38> ", " <RGB:0.87,0.88,0.9> "
local function esc(s) s = tostring(s or ""); s = string.gsub(s, "<", "("); s = string.gsub(s, ">", ")"); return s end
-- one decimal (Kahlua's string.format has no %.1f)
local function one(x)
    local n = math.floor((tonumber(x) or 0) * 10 + 0.5)
    if n < 0 then n = 0 end
    return A.intStr(math.floor(n / 10)) .. "." .. string.char(48 + n % 10)
end
local function secs(ms) return one((tonumber(ms) or 0) / 1000) end
local function short(name)
    local k = A.knownOf(name)
    return (k and k.short) or tostring(name or "?")
end

----------------------------------------------------------------------------------------------------------------
-- asking / doing
----------------------------------------------------------------------------------------------------------------
K.advOpen = false
function K.ask() return A.ask(playerOf()) end
function K.state() return A.last end
function K.setup()
    local s = A.last
    local out = {}
    if type(s) == "table" and type(s.setup) == "table" then for k, v in pairs(s.setup) do out[k] = v end end
    return out
end
function K.send(action, arg, setup)
    local ok, why = A.act(playerOf(), { action = action, arg = arg, setup = setup })
    if not ok then K.ask() end
    return ok, why
end
local WHY = {
    notHost = "The AI is set up on each player's own PC.", badAction = "The helper doesn't know that one.",
    badModel = "That model name isn't allowed.", waiting = "The helper hasn't picked up the last request yet. Is it running?",
    write = "Couldn't write to Zomboid\\Lua.", bad = "Bad request.",
}
function A.onDone(payload)
    local text
    if type(payload) ~= "table" then return end
    if payload.ok then text = tr("Sent", "Sent to the AI helper.")
    else text = tr("Why_" .. tostring(payload.why), WHY[payload.why] or tostring(payload.why)) end
    if fn(M, "momToast") then pcall(M.momToast, text) end
end
-- the doctor: the game side (version + settings) goes in the helper's report, written here (the helper is on this PC)
function K.doctor()
    local lines = { "A-Life NPC Overhaul (game side) " .. A.VERSION, "bridge protocol " .. tostring(M.VERSION),
        "multiplayer " .. tostring(not K.isSP()) }
    local keys = {}
    for k, v in pairs(M.settings or {}) do if type(k) == "string" and type(v) ~= "table" and type(v) ~= "function" then keys[#keys + 1] = k end end
    table.sort(keys)
    for _, k in ipairs(keys) do lines[#lines + 1] = k .. "=" .. string.gsub(tostring(M.settings[k]), "[\r\n]", " ") end
    A.writeLines(A.FILES.game, lines)
    K.send("doctor")
end
-- the folder with Setup.cmd. getModInfoByID(id):getDir() = the mod's root (common, 42, bridge): read in the
-- decompiled 42.21 ChooseGameInfo.Mod.
function K.bridgeDir()
    local d = nil
    pcall(function() d = getModInfoByID("ALifeChatPlus"):getDir() end)
    if type(d) == "string" and d ~= "" then
        d = string.gsub(d, "[/\\]+$", "")
        return d .. "\\bridge", true
    end
    return "Steam\\steamapps\\workshop\\content\\108600\\3827364142\\mods\\ALifeChatPlus\\bridge", false
end
-- 0.8.12: open that folder in Windows Explorer. Vanilla showFolderInDesktop (LuaManager.GlobalObject, 42.21): it only
-- opens folders under the game's own folders and the mod folders (ZomboidFileSystem.validatePrefix), which the
-- bridge folder is. If it can't: the path goes on your clipboard and the how-to opens.
function K.openFolder()
    local dir, real = K.bridgeDir()
    local ok = false
    if real and type(showFolderInDesktop) == "function" then ok = pcall(showFolderInDesktop, dir) end
    if ok then
        if fn(M, "momToast") then pcall(M.momToast, tr("FolderOpened", "Opened the AI folder. First time: double-click Setup.cmd. Already set up: Restart AI helper.cmd.")) end
        ALifeHealth.note(TAG, "opened " .. dir)
        return true
    end
    pcall(function() Clipboard.setClipboard(dir) end)
    K.helperHelp(true)
    return false
end

-- 0.8.12 (Rock List 2): YOUR AI RULES. The bridge reads its prompt text from bridge\prompts.txt and your own
-- Zomboid\Lua\alifeai_prompts.txt, live (alifetalk_prompts.py). This makes a starter file if there is none (never
-- overwrites one) and opens Zomboid\Lua (vanilla showFolderInDesktop with Core.getMyDocumentFolder(); unverified that
-- the user folder passes validatePrefix: if not, the path goes on the clipboard).
K.RULES_STARTER = {
    "# Your own AI rules for A-Life NPC Overhaul. Read LIVE: save this file and the next line anyone says uses it.",
    "# Copy any [SECTION] from the mod's bridge\\prompts.txt here and change it. This file survives mod updates.",
    "# [extra] is added to every prompt. [mode.reply] only to answers to you; also mode.ambient, mode.chime, mode.react.",
    "# Lines starting with '# ' are notes. Delete a section to go back to the mod's text.",
    "", "[extra]", "", "[mode.reply]", "" }
function K.rulesFile()
    local had = false
    pcall(function() local r = getFileReader("alifeai_prompts.txt", false); if r then had = true; r:close() end end)
    if not had then
        pcall(function()
            local w = getFileWriter("alifeai_prompts.txt", true, false)
            w:write(table.concat(K.RULES_STARTER, "\n") .. "\n")
            w:close()
        end)
    end
    local dir = nil
    pcall(function() dir = Core.getMyDocumentFolder() .. getFileSeparator() .. "Lua" end)
    local ok = false
    if dir and type(showFolderInDesktop) == "function" then ok = pcall(showFolderInDesktop, dir) end
    local text = had and tr("RulesOpened", "Your AI rules: alifeai_prompts.txt in Zomboid\\Lua. Save it and the next line uses it.")
        or tr("RulesMade", "Made alifeai_prompts.txt in Zomboid\\Lua. Write your rules under [extra], save, and the next line uses it.")
    -- pre-1.0: the folder holds many files; say WHICH one, and put the file's full path on the clipboard
    local full = tostring(dir or "Zomboid\\Lua") .. "\\alifeai_prompts.txt"
    pcall(function() Clipboard.setClipboard(full) end)
    if ok then text = text .. " " .. tr("RulesPick", "Open the file named alifeai_prompts.txt in the folder that just opened (its full path is on your clipboard).")
    else text = text .. " " .. tr("RulesClip", "(File path copied: paste it in Explorer's address bar.)") end
    if fn(M, "momToast") then pcall(M.momToast, text) end
    return had, ok
end

----------------------------------------------------------------------------------------------------------------
-- texts
----------------------------------------------------------------------------------------------------------------
local WORD = { ok = GREEN .. "DONE", busy = YELLOW .. "WORKING", bad = RED .. "NEEDS YOU", todo = GOLD .. "YOUR TURN",
    wait = GREY .. "WAITING", skip = GREY .. "NOT NEEDED" }
local TITLE = { helper = "1. The AI helper", ollama = "2. Ollama (runs the AI on your PC)", model = "3. Pick a model",
    test = "4. Warm up and test", ready = "5. Done" }

local function jobLine(job)
    if job == nil then return "" end
    local pct = math.floor(tonumber(job.progress) or 0)
    local gb = ""
    if job.done and job.total and job.total > 0 then gb = " (" .. one(job.done / 1024) .. " of " .. one(job.total / 1024) .. " GB)" end
    return pct .. "%" .. gb
end
function K.stepText(step, s)
    local st, why, job = step.state, step.why, s and s.job or nil
    local id = step.id
    if id == "helper" then
        if st == "ok" then
            local auto = s.autostart == "on" and tr("AutoOn", "It starts with Windows.") or (s.autostart == "off" and tr("AutoOff", "It does NOT start with Windows: after a restart you run it by hand.") or "")
            return tr("HelperOk", "Running{1}.", s.helperVer and (" (v" .. esc(s.helperVer) .. ")") or "") .. " " .. auto
        end
        return tr("HelperDown", "Not running. Open the mod's bridge folder and run \"Restart AI helper.cmd\" (first time: \"Setup.cmd\"). After that it starts with Windows. Hover \"Start the helper\" for why the game can't do it.")
    elseif id == "ollama" then
        if st == "ok" then return tr("OllamaOk", "Installed and running.") end
        if st == "skip" then return tr("OllamaCloud", "You use a cloud AI. No Ollama needed.") end
        if why == "installing" then return tr("OllamaInstalling", "Installing... If Windows asks, click Yes. {1}", esc(job and job.msg or "")) end
        if why == "starting" then return tr("OllamaStarting", "Starting Ollama...") end
        if st == "wait" then return tr("WaitHelper", "Waiting for step 1.") end
        local failed = job and job.action == "get_ollama" and job.state == "failed"
        return tr("OllamaMissing", "Not installed. Press \"Get Ollama\".") .. (failed and (RED .. " " .. esc(job.msg) .. TXT) or "")
    elseif id == "model" then
        local name = esc(short(s and s.modelName))
        if st == "ok" then return tr("ModelOk", "Using {1}. Press \"Pick model\" to change.", name) end
        if st == "skip" then return tr("ModelCloud", "Your cloud AI picks the model (Zomboid\\Lua\\alifeai_cloud.txt).") end
        if why == "pulling" then return tr("ModelPulling", "Downloading {1}: {2}", esc(short(job.arg)), jobLine(job)) end
        if why == "downloading" then return tr("ModelDownloading", "Downloading {1} (a few minutes)...", name) end
        if st == "wait" then return tr("WaitOllama", "Waiting for Ollama.") end
        local failed = job and job.action == "pull" and job.state == "failed"
        return tr("ModelMissing", "{1} isn't downloaded yet. Press \"Pick model\".", name) .. (failed and (RED .. " " .. esc(job.msg) .. TXT) or "")
    elseif id == "test" then
        if st == "skip" then return tr("TestCloud", "Cloud AI: test by talking to someone.") end
        if st == "wait" then return tr("WaitModel", "Waiting for the model.") end
        if st == "busy" then return tr("Testing", "Loading the model and asking it one line... (big models: up to a few minutes the first time)") end
        if st == "bad" then return tr("TestFailed", "No answer: {1}", esc(job and job.msg or "?")) end
        if st == "todo" then return tr("TestTodo", "Press \"Test reply\". The AI loads and answers once, so you see how fast it is.") end
        local out = tr("TestOk", "Answered in {1} s (loading {2} s). On the graphics card: {3}. About {4} words a second.",
            secs(job.ms), secs(job.loadMs), job.gpu and (math.floor(job.gpu) .. "%") or "?", job.tps and math.floor(job.tps * 0.75) or "?")
        if job.reply and job.reply ~= "" then out = out .. " <LINE> " .. GREY .. "\"" .. esc(job.reply) .. "\"" .. TXT end
        if why == "slow" then
            out = out .. " <LINE> " .. RED .. tr("TestSlow", "Slow. Try a smaller model, or a smaller reading size (Advanced). Hover \"Test reply\" for why.") .. TXT
        end
        return out
    elseif id == "ready" then
        if st == "ok" then return GREEN .. tr("Ready", "AI ready. People answer in their own words.") .. TXT
            .. (why == "talkStarting" and (" " .. GREY .. tr("TalkStarting", "(free chat still starting)") .. TXT) or "") end
        if st == "busy" then return tr("Warming", "Warming up the AI...") end
        if st == "wait" then return tr("WaitModel", "Waiting for the model.") end
        if why == "nopython" then return RED .. tr("NoPython", "Python is missing, so free chat is off. Run Setup.cmd again (it installs Python).") .. TXT end
        return RED .. tr("BridgeBad", "The AI bridge {1}: {2}", esc(why), esc(s.bridgeErr or s.talkErr or "")) .. TXT
            .. " <LINE> " .. tr("BridgeBadTip", "Press \"Restart AI\". Still broken: \"Doctor check\" and send the file it makes.")
    end
    return ""
end

local ADV_TEXT = {
    num_ctx = { "Reading size", "How much the AI reads at once: who they are, what's going on, what they remember. Bigger = they know more, but it needs more video memory and can get very slow when it doesn't fit. Safe: 4096. 8192 on 12 GB cards. (num_ctx)" },
    num_predict = { "Reply length", "The longest reply, in tokens (a token is about 3/4 of a word). Bigger = longer replies, a bit slower. Safe: 60 to 120. (num_predict)" },
    timeout = { "Wait limit", "Seconds the chat engine waits for one reply before giving up and letting A-Life answer. Slow PC: raise it. Safe: 20 to 45. (timeout)" },
    warmup = { "Load wait", "Seconds to wait for the model to load when the game starts. Big models load slowly the first time. Safe: 120 to 300. (warmup)" },
    fallback = { "Backup model", "If your model doesn't load in time, people use this one for that game, and a letter tells you. It must be downloaded. Safe: a small one, like gemma3:4b. (fallback)" },
    profile = { "How much they're told", "How much the AI is told every time someone talks. Lite: who they are, their mood, what's happening, what they remember (best for 3B models). Normal: plus their group, its rules, friends and enemies (4B). Full: everything, all ties and longer memory (7B and up). Auto picks by model size. Small models get confused by too much. (profile)" },
    ptt = { "Push-to-talk key", "Hold this key, say it out loud, let go: they hear you. Works even when the game window isn't focused, so pick a key you don't type with. Needs the voice part of the helper (Setup.cmd). (ptt)" },
}
local PTT_TIP = {
    CapsLock = "Caps Lock. The default. You rarely need it in game.", Mouse4 = "The back thumb button on your mouse.",
    Mouse5 = "The front thumb button on your mouse.", MiddleMouse = "Press the mouse wheel. Careful: zoom uses the wheel.",
    RightCtrl = "Right Ctrl.", RightAlt = "Right Alt (AltGr on some keyboards).", ScrollLock = "Scroll Lock. Nothing else uses it.",
    Pause = "Pause/Break.", Backtick = "The key under Esc.",
}
function K.advValue(key)
    local v = K.setup()[key]
    if v == nil then local a = A.advOf(key); v = a and a.default end
    return v
end
function K.text()
    local s = A.last
    local out = { " <SIZE:medium> " .. GOLD .. tr("Title", "AI setup") .. TXT .. " <SIZE:small> <LINE> " }
    if type(s) ~= "table" then
        out[#out + 1] = GREY .. tr("Asking", "Asking...") .. TXT
        return table.concat(out)
    end
    if not K.isSP() then
        out[#out + 1] = GREY .. tr("MPOwn", "Multiplayer: this is your own AI, on your PC. The NPCs you talk to answer with it, and everyone hears them. No AI here: they use A-Life's own lines.") .. TXT .. " <LINE> "
    end
    if s.power == "off" then
        out[#out + 1] = YELLOW .. tr("PowerOffText", "The AI is turned off. Nothing is started and nothing is asked. People use A-Life's own lines. Press \"AI: off\" to turn it back on.") .. TXT
        return table.concat(out)
    end
    out[#out + 1] = GREY .. tr("Intro", "Top to bottom. Each step turns green when it's done. Hover any button for more.") .. TXT .. " <LINE> "
    for _, step in ipairs(A.steps(s)) do
        out[#out + 1] = " <LINE> " .. WORD[step.state] .. TXT .. "   " .. GOLD .. tr("Step_" .. step.id, TITLE[step.id]) .. TXT .. " <LINE> "
        out[#out + 1] = K.stepText(step, s) .. " <LINE> "
    end
    if s.waiting then out[#out + 1] = " <LINE> " .. YELLOW .. tr("Waiting", "Waiting for the helper to pick up your request...") .. TXT .. " <LINE> " end
    local job = s.job
    if job and (job.action == "restart" or job.action == "pick" or job.action == "delete" or job.action == "doctor") and job.t and nowMs() - job.t < 60000 then
        local col = job.state == "failed" and RED or GREY
        out[#out + 1] = " <LINE> " .. col .. tr("Job_" .. job.action, job.action) .. ": " .. esc(job.msg or job.state) .. TXT .. " <LINE> "
    end
    if K.advOpen then
        out[#out + 1] = " <LINE> " .. GOLD .. tr("AdvTitle", "ADVANCED") .. TXT .. "  " .. GREY .. tr("AdvTag", "(a change restarts the AI: about a minute without AI replies)") .. TXT .. " <LINE> "
        for _, a in ipairs(A.ADV) do
            if a.key ~= "ptt" then
                local t = ADV_TEXT[a.key]
                local v = K.advValue(a.key)
                out[#out + 1] = tr("Adv_" .. a.key, t[1]) .. ": " .. GOLD .. esc(a.model and short(v) or v) .. TXT
                    .. (K.setup()[a.key] == nil and (GREY .. " " .. tr("Default", "(default)") .. TXT) or "") .. " <LINE> "
            end
        end
    end
    do
        local c = A.readCloud()
        out[#out + 1] = " <LINE> " .. GOLD .. tr("CloudTitle", "CLOUD AI") .. TXT .. "  " .. GREY .. tr("CloudTag", "(no graphics card needed: a paid or free online AI)") .. TXT .. " <LINE> "
        if c.enabled then
            out[#out + 1] = tr("CloudOn", "On: {1}, model {2}.", esc(K.providerName(c.url)), esc(c.model or "?"))
            local err = K.cloudErr(s.cloud)
            out[#out + 1] = (err and (" " .. RED .. err .. TXT) or "") .. " <LINE> "
        else
            out[#out + 1] = tr("CloudOff", "Off. Press Cloud AI to use one instead of your PC.") .. " <LINE> "
        end
    end
    out[#out + 1] = " <LINE> " .. GOLD .. tr("GameTitle", "IN THIS GAME") .. TXT .. "  " .. GREY .. tr("GameTag", "(kept with this world; beats the sandbox page)") .. TXT .. " <LINE> "
    out[#out + 1] = tr("GameWait", "They wait for the AI {1} s, then answer with A-Life's own line.", K.waitSec()) .. " <LINE> "
    out[#out + 1] = tr("GameLang", "They speak: {1}.", esc(K.langName())) .. "  " .. tr("GameVoice", "Voice (talk out loud, NPC voices): {1}.", M.settings.voice == false and tr("Off", "off") or tr("On", "on")) .. " <LINE> "
    return table.concat(out)
end

----------------------------------------------------------------------------------------------------------------
-- menus (every option has a hover tip)
----------------------------------------------------------------------------------------------------------------
local function tip(option, text)
    pcall(function()
        local t = ISInventoryPaneContextMenu.addToolTip()
        t.description = text
        option.toolTip = t
    end)
end
local function speedWord(n) return n == 3 and "fast" or (n == 2 and "medium" or "slow") end
local function modelTip(k, gb)
    if k == nil then return tr("TipUnknown", "Not on the known-good list. Size on disk: {1} GB.", gb or "?") end
    return tr("TipModel", "{1} <LINE> Download: about {2} GB. Video memory: about {3} GB. Speed: {4}. {5}",
        k.what, k.gb, k.vram, tr("Speed_" .. speedWord(k.speed), speedWord(k.speed)),
        k.open and tr("Uncensored", "Uncensored: no refusals.") or tr("Censored", "Filtered: may refuse rough lines."))
end
function K.modelMenu(cm)
    local s = A.last or {}
    local have = {}
    local current = s.modelName
    local mine = cm:addOption(tr("OnYourPC", "On your PC"), nil, nil)
    local sub = ISContextMenu:getNew(cm)
    cm:addSubMenu(mine, sub)
    if #(s.models or {}) == 0 then local o = sub:addOption(tr("NoneYet", "None yet"), nil, nil); o.notAvailable = true end
    for _, m in ipairs(s.models or {}) do
        have[m.n] = true
        have[string.gsub(m.n, ":latest$", "")] = true
        local inUse = m.n == current or m.n == tostring(current) .. ":latest"
        local o = sub:addOption(short(m.n) .. (inUse and (" " .. tr("InUse", "(in use)")) or ""), nil, nil)
        tip(o, modelTip(A.knownOf(m.n), one(m.gb)))
        local mm = ISContextMenu:getNew(sub)
        sub:addSubMenu(o, mm)
        local use = mm:addOption(tr("UseIt", "Use this one"), nil, function()
            local setup = K.setup(); setup.model = m.n
            K.send("pick", nil, setup)
        end)
        tip(use, tr("TipUse", "People talk with this model from now on. The AI restarts (about a minute)."))
        if inUse then use.notAvailable = true end
        local del = mm:addOption(tr("DeleteIt", "Delete (frees {1} GB)", one(m.gb)), nil, function() K.send("delete", m.n) end)
        tip(del, inUse and tr("TipDelInUse", "It's in use. Pick another one first.") or tr("TipDel", "Removes it from your PC. You can download it again any time."))
        if inUse then del.notAvailable = true end
    end
    local dl = cm:addOption(tr("Download", "Download a new one"), nil, nil)
    tip(dl, tr("TipDownload", "Known-good models. Hover one for its size, video memory, speed, and if it's filtered. Your video memory: Task Manager > Performance > GPU > Dedicated GPU memory."))
    local dsub = ISContextMenu:getNew(cm)
    cm:addSubMenu(dl, dsub)
    local busy = s.job and s.job.state == "running"
    for _, k in ipairs(A.KNOWN) do
        if not have[k.name] then
            local o = dsub:addOption((k.short or k.name) .. " - " .. k.gb .. " GB", nil, function() K.send("pull", k.name) end)
            tip(o, modelTip(k) .. (busy and (" <LINE> " .. tr("TipBusy", "Wait: the helper is busy with another job.")) or ""))
            if busy then o.notAvailable = true end
        end
    end
end
function K.advMenu(cm, key)
    local a = A.advOf(key)
    local t = ADV_TEXT[key]
    local cur = K.advValue(key)
    local function set(v)
        local setup = K.setup(); setup[key] = v
        K.send("restart", nil, setup)
    end
    if a.model then
        for _, m in ipairs((A.last or {}).models or {}) do
            local o = cm:addOption(short(m.n) .. (m.n == cur and " *" or ""), nil, function() set(m.n) end)
            tip(o, t[2])
        end
    elseif a.words then
        for _, v in ipairs(a.words) do
            local o = cm:addOption(tr("Word_" .. v, v) .. (v == a.default and (" " .. tr("Default", "(default)")) or "") .. (v == cur and " *" or ""), nil, function() set(v) end)
            tip(o, (key == "ptt" and PTT_TIP[v]) or (key == "ptt" and tr("TipFKey", "A function key. Check the game doesn't use it (Options > Keys).")) or t[2])
        end
    else
        for _, v in ipairs(a.choices) do
            local o = cm:addOption(tostring(v) .. (v == a.default and (" " .. tr("Default", "(default)")) or "") .. (v == cur and " *" or ""), nil, function() set(v) end)
            tip(o, t[2])
        end
    end
    local back = cm:addOption(tr("BackDefault", "Back to default"), nil, function()
        local setup = K.setup(); setup[key] = nil
        K.send("restart", nil, setup)
    end)
    tip(back, tr("TipBackDefault", "Uses model.txt, or the built-in default."))
end
function K.helperHelp(copied)
    local text = " <SIZE:medium> " .. tr("HelpHelperT", "Start the AI helper") .. " <LINE> <SIZE:small> "
        .. (copied and (tr("Copied", "Couldn't open the folder for you, so its path is on your clipboard: Windows key + E, click the address bar, Ctrl+V, Enter.") .. " <LINE> <LINE> ") or "")
        .. tr("HelpHelper", "The game isn't allowed to start programs on your PC (that keeps you safe from mods). The AI helper is a small program from this mod that starts the AI when the game opens and stops it when the game closes. <LINE> <LINE> 1. Open this folder: <LINE> {1} <LINE> 2. First time: double-click Setup.cmd. It installs what's missing and makes the helper start with Windows. <LINE> 3. Already set up: double-click \"Restart AI helper.cmd\". <LINE> <LINE> Then come back here. Step 1 turns green within a few seconds.", esc(K.bridgeDir()))
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    local w, h = math.min(620, sw - 40), math.min(340, sh - 40)
    local modal = ISModalRichText:new((sw - w) / 2, (sh - h) / 2, w, h, text, false)
    modal:initialise(); modal:addToUIManager()
end

----------------------------------------------------------------------------------------------------------------
-- the buttons (which show depends on where you are)
----------------------------------------------------------------------------------------------------------------
function K.actions(menuAt)
    local s = A.last
    -- pre-1.0: bug reports (per PC: everyone gets the switch, host or not)
    local bug, bugSend = nil, nil
    if type(ALifeBugReports) == "table" and fn(ALifeBugReports, "button") then pcall(function() bug = ALifeBugReports.button() end) end
    if type(ALifeBugReports) == "table" and fn(ALifeBugReports, "sendButton") then pcall(function() bugSend = ALifeBugReports.sendButton() end) end
    if type(s) ~= "table" or not s.host then
        local l = { { label = tr("BtnRefresh", "Refresh"), tip = tr("TipRefresh", "Check again."), fn = function() K.ask() end } }
        if bugSend then l[#l + 1] = bugSend end
        if bug then l[#l + 1] = bug end
        return l
    end
    local steps = {}
    for _, st in ipairs(A.steps(s)) do steps[st.id] = st end
    local up = s.helper == "up"
    local cloud = s.ollama == "cloud"
    local list = {}
    local function add(a) list[#list + 1] = a end
    add({ label = tr("BtnFolder", "Open the AI folder"), accent = not up,
        tip = tr("TipFolder", "Opens the mod's bridge folder in Windows Explorer: Setup.cmd (first time), Restart AI helper.cmd, Set up cloud AI.cmd. The game can't run them for you (safety rule), but it can take you there."),
        fn = function() K.openFolder() end })
    if not up then
        add({ label = tr("BtnHelper", "Start the helper"), accent = true,
            tip = tr("TipHelper", "The game can't start programs on your PC (safety rule). Click for the two-click way to start it."),
            fn = function() K.helperHelp() end })
    end
    if up then
        local mode = K.mode(s)
        local name = mode == "cloud" and tr("ModeCloud", "Cloud") or (mode == "off" and tr("ModeOff", "Off") or tr("ModeLocal", "Local"))
        add({ label = tr("BtnMode", "AI mode: {1}", name), accent = mode == "off",
            tip = tr("TipMode", "Local: the AI runs on your PC (Ollama). Cloud: an online AI you pay for with your own key. Off: nothing is started or asked, even after a restart; people use A-Life's own lines. Switching restarts the AI."),
            fn = function(win, btn) K.modeMenu(menuAt(win, btn)) end })
    end
    if bugSend then add(bugSend) end
    if bug then add(bug) end
    if s.power == "off" then return list end
    if up and steps.ollama.state == "bad" then
        add({ label = tr("BtnGetOllama", "Get Ollama"), accent = true,
            tip = tr("TipGetOllama", "The helper downloads Ollama (the free program that runs the AI on your PC) with Windows' own installer. Windows asks once: click Yes. About 1 GB. No winget on your PC: your browser opens the download page."),
            fn = function() K.send("get_ollama") end })
    end
    if up and not cloud and s.ollama == "ok" then
        add({ label = tr("BtnPick", "Pick model"), accent = steps.model.state == "bad",
            tip = tr("TipPick", "Use, download or delete AI models. Hover each one for size, video memory, speed and if it's filtered."),
            fn = function(win, btn) K.modelMenu(menuAt(win, btn)) end })
    end
    if up and not cloud then
        add({ label = tr("BtnTest", "Test reply"), accent = steps.test.state == "todo",
            tip = tr("TipTest", "Loads the model and asks for one line. Shows how long it took and how much ran on the graphics card. Under 100% on the graphics card = part runs on the CPU, which is slow: pick a smaller model or a smaller reading size."),
            fn = function() K.send("test") end })
    end
    if up and (s.autostart == "on" or s.autostart == "off") then
        local on = s.autostart == "on"
        add({ label = on and tr("BtnAutoOn", "Starts with Windows: on") or tr("BtnAutoOff", "Starts with Windows: off"),
            tip = tr("TipAuto", "On: the helper starts quietly when Windows starts and waits for the game (it uses almost nothing until the game opens). Off: run \"Restart AI helper.cmd\" yourself before playing. Click to switch."),
            fn = function() K.send("autostart", on and "off" or "on") end })
    end
    if up and M.settings.voice ~= false then
        add({ label = tr("BtnPtt", "Talk key: {1}", tr("Word_" .. tostring(K.advValue("ptt")), tostring(K.advValue("ptt")))),
            tip = ADV_TEXT.ptt[2] .. " <LINE> " .. tr("AdvRestart", "Restarts the AI."),
            fn = function(win, btn) K.advMenu(menuAt(win, btn), "ptt") end })
    end
    add({ label = tr("BtnWait", "AI wait: {1} s", K.waitSec()),
        tip = tr("TipWait", "How long someone waits for the AI before answering with A-Life's own line. Slow PC or cloud: raise it. Fast PC: lower it so nobody stands there silent. Safe: 7 to 15."),
        fn = function(win, btn) K.gameMenu(menuAt(win, btn), "wait") end })
    add({ label = tr("BtnLang", "Language: {1}", K.langName()),
        tip = tr("TipLang", "The language people answer in. Auto: whatever language you type. Needs the AI; without it A-Life's own lines stay English."),
        fn = function(win, btn) K.gameMenu(menuAt(win, btn), "lang") end })
    add({ label = M.settings.voice == false and tr("BtnVoiceOff", "Voice: off") or tr("BtnVoiceOn", "Voice: on"),
        tip = tr("TipVoice", "On: hold your talk key and say it out loud, and NPC lines can be spoken. Off: typing only. Click to switch."),
        fn = function() K.setGame("Voice", M.settings.voice == false) end })
    if up then
        add({ label = tr("BtnRestart", "Restart AI"),
            tip = tr("TipRestart", "Stops and starts the AI bridges. Use it when replies stop coming. About a minute without AI replies."),
            fn = function() K.send("restart") end })
    end
    add({ label = tr("BtnDoctor", "Doctor check"),
        tip = tr("TipDoctor", "Packs the helper's logs, your AI settings and the mod's settings into one file: Zomboid\\Lua\\alifeai_doctor.txt. Send that file with a bug report. Your cloud key is never in it."),
        fn = function() if up then K.doctor() else K.helperHelp() end end })
    add({ label = K.advOpen and tr("BtnAdvClose", "Advanced -") or tr("BtnAdvOpen", "Advanced +"),
        tip = tr("TipAdv", "Fine-tuning for people who want it. Each one says what it does and a safe range."),
        fn = function(win) K.advOpen = not K.advOpen; if win then win.sig = nil; win:refresh() end end })
    if K.advOpen then -- 0.8.12: your own AI rules file (on this PC, single player or MP)
        add({ label = tr("BtnRules", "Your AI rules"),
            tip = tr("TipRules", "How people talk is written in plain text files the AI reads live. This opens your own file (Zomboid\\Lua\\alifeai_prompts.txt, made if missing): house rules under [extra], or copy a section from the mod's bridge\\prompts.txt and change it. Save and the next line uses it. Survives mod updates."),
            fn = function() K.rulesFile() end })
    end
    if K.advOpen and up then
        for _, a in ipairs(A.ADV) do
          if a.key ~= "ptt" then
            local t = ADV_TEXT[a.key]
            add({ label = tr("Adv_" .. a.key, t[1]), tip = tr("AdvTip_" .. a.key, t[2]) .. " <LINE> " .. tr("AdvRestart", "Restarts the AI."),
                fn = function(win, btn) K.advMenu(menuAt(win, btn), a.key) end })
          end
        end
    end
    return list
end

----------------------------------------------------------------------------------------------------------------
-- 0.8.12: IN THIS GAME (AI wait, language, voice). Kept with this world, beats the sandbox page (M.sbSetOverride).
----------------------------------------------------------------------------------------------------------------
function K.isSP() return not (M.isSP and not M.isSP()) end
function K.waitSec() return math.floor((tonumber(M.settings.fallbackMs) or 20000) / 1000 + 0.5) end
function K.langName()
    local L = ALifeLanguage
    if type(L) ~= "table" or type(L.list) ~= "table" then return "Auto" end
    local i = tonumber(M.settings.npcLanguage)
    if i == nil then pcall(function() i = tonumber(SandboxVars.ALifeChatPlus.NpcLanguage) end) end
    local e = L.list[i or 1] or L.list[1]
    return e[1] == "auto" and "Auto" or e[2]
end
K.WAITS = { 3, 5, 7, 9, 12, 15, 20, 30 }
-- k = the sandbox option (AIWaitSec seconds, NpcLanguage 1-14, Voice true/false)
function K.setGame(k, v)
    if fn(M, "sbSetOverride") and M.sbSetOverride(k, v) then return true end
    if k == "AIWaitSec" then M.settings.fallbackMs = v * 1000
    elseif k == "NpcLanguage" then M.settings.npcLanguage = v
    elseif k == "Voice" then M.settings.voice = v end
    return true
end
function K.gameMenu(cm, which)
    if which == "wait" then
        local cur = K.waitSec()
        for _, n in ipairs(K.WAITS) do
            local o = cm:addOption(n .. " s" .. (n == 20 and (" " .. tr("Default", "(default)")) or "") .. (n == cur and " *" or ""), nil, function() K.setGame("AIWaitSec", n) end)
            tip(o, n <= 5 and tr("TipWaitShort", "Fast PCs and small models only, or A-Life answers most of the time.")
                or (n >= 15 and tr("TipWaitLong", "For slow PCs, big models and cloud AI. Long silences while they think.")
                or tr("TipWaitMid", "Works for most PCs.")))
        end
    else
        local L = ALifeLanguage
        for i, e in ipairs((type(L) == "table" and L.list) or {}) do
            local o = cm:addOption(e[2], nil, function() K.setGame("NpcLanguage", i) end)
            tip(o, e[1] == "auto" and tr("TipLangAuto", "They answer in the language you type. Best if you switch languages.") or tr("TipLangOne", "They always answer in {1}, whatever you type.", e[2]))
        end
    end
    local back = cm:addOption(tr("BackSandbox", "Back to the sandbox setting"), nil, function()
        if fn(M, "sbSetOverride") then M.sbSetOverride(which == "wait" and "AIWaitSec" or "NpcLanguage", nil) end
    end)
    tip(back, tr("TipBackSandbox", "Forget the choice made here and use this world's sandbox page again."))
end

----------------------------------------------------------------------------------------------------------------
-- 0.8.12: CLOUD AI form (this PC: single player or your own MP client). The key box is masked and starts empty: empty = keep the saved key. The
-- key is written only to this PC's Zomboid/Lua/alifeai_cloud.txt (ALifeAISetup.writeCloud), never shown or logged.
----------------------------------------------------------------------------------------------------------------
function K.providerName(url)
    for _, p in ipairs(A.PROVIDERS) do if p.url == url then return p.name end end
    return tostring(url or "?")
end
local CLOUD_ERR = { badkey = "The key was rejected.", nomodel = "The provider doesn't know that model.", credits = "Out of credits.",
    unreachable = "Can't reach the provider (internet or address).", ratelimit = "The provider is rate-limiting you.",
    cap = "Your hourly limit is reached." }
-- the AI mode dropdown: Local / Cloud / Off
function K.mode(s)
    if s.power == "off" then return "off" end
    return s.ollama == "cloud" and "cloud" or "local"
end
function K.modeMenu(cm)
    local s = A.last or {}
    local cur = K.mode(s)
    local function apply()
        if s.power == "off" then K.send("power", "on") else K.send("restart") end
    end
    local function mark(m) return (m == cur) and " *" or "" end
    tip(cm:addOption(tr("ModeLocal", "Local") .. mark("local"), nil, function()
        if A.readCloud().enabled then A.writeCloud({ enabled = false }) end
        apply()
    end), tr("TipModeLocal", "The AI runs on your PC with Ollama. Needs a graphics card for good speed."))
    do
        tip(cm:addOption(tr("ModeCloud", "Cloud") .. mark("cloud"), nil, function()
            local c = A.readCloud()
            if c.exists and c.hasKey and A.validUrl(c.url) and A.validCloudModel(c.model) then
                local ok = A.writeCloud({ enabled = true })
                if ok then apply() else K.cloudForm() end
            else
                K.cloudForm()
            end
        end), tr("TipModeCloud", "An online AI with your own key. First time it opens the cloud form; after that it switches straight over."))
        tip(cm:addOption(tr("ModeCloudSet", "Cloud settings..."), nil, function() K.cloudForm() end),
            tr("TipModeCloudSet", "Change the provider, key, model and hourly cap."))
    end
    tip(cm:addOption(tr("ModeOff", "Off") .. mark("off"), nil, function()
        if s.power ~= "off" then K.send("power", "off") end
    end), tr("TipModeOff", "Stops the AI and keeps it off, even after a restart, until you pick Local or Cloud. Nothing nags you."))
end
function K.cloudErr(code) if code and CLOUD_ERR[code] then return tr("CloudErr_" .. code, CLOUD_ERR[code]) end return nil end
local CLOUD_WHY = { url = "That address doesn't look right (it starts with https://).", key = "That key has a character keys don't use. Copy it again, just the key.",
    model = "Type the model's name exactly as your provider lists it.", write = "Couldn't write the file in Zomboid/Lua.", bad = "Bad request." }
-- form: { url, key, model (text boxes with getText/setText), bg, cap, msg, close }
function K.cloudSave(form, on)
    local c = A.readCloud()
    local data = { enabled = on, url = form.url:getText(), key = A.cleanKey(form.key:getText()), model = form.model:getText(),
        background = form.bg, cap = form.cap }
    if type(data.url) == "string" then data.url = string.gsub(data.url, "^%s+", ""); data.url = string.gsub(data.url, "%s+$", "") end
    if type(data.model) == "string" then data.model = string.gsub(data.model, "^%s+", ""); data.model = string.gsub(data.model, "%s+$", "") end
    if not on then
        if data.url == "" or not A.validUrl(data.url) then data.url = c.url end
        if data.model == "" or not A.validCloudModel(data.model) then data.model = c.model end
        if data.key ~= "" and not A.validKey(data.key) then data.key = "" end
    end
    local ok, why = A.writeCloud(data)
    if not ok then form.msg = tr("CloudWhy_" .. tostring(why), CLOUD_WHY[why] or tostring(why)); return false end
    form.key:setText("")
    form.msg = nil
    K.send("restart")
    if fn(M, "momToast") then pcall(M.momToast, on and tr("CloudSaved", "Cloud AI saved. The AI restarts (about a minute). If it fails, the AI tab says why.") or tr("CloudOffSaved", "Cloud AI off. Back to the AI on your PC.")) end
    form:close()
    return true
end
function K.cloudForm()
    local T = M.Theme
    if T == nil or ALifeLLMTalkWindow == nil then return end
    if K.cloudWin then pcall(function() K.cloudWin:close() end) end
    ALifeAICloudForm = ALifeAICloudForm or ALifeLLMTalkWindow:derive("ALifeAICloudForm")
    local F = ALifeAICloudForm
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    local w, h = 560, 330
    local win = ALifeLLMTalkWindow.new(F, math.floor((sw - w) / 2), math.floor((sh - h) / 2), w, h, tr("CloudFormTitle", "Cloud AI"))
    local c = A.readCloud()
    win.bg, win.cap = c.background or "off", c.cap or 150
    function F:createChildren()
        ALifeLLMTalkWindow.createChildren(self)
        local top = self:contentTop()
        local x, fw, rowH = 120, self.width - 130, 24
        local function entry(y, text, masked, hint)
            local e = ISTextEntryBox:new(text or "", x, y, fw, rowH)
            e:initialise(); e:instantiate()
            if masked then pcall(function() e:setMasked(true) end) end
            pcall(function() e:setMaxTextLength(masked and 300 or 200) end)
            if hint then pcall(function() e:setPlaceholderText(hint) end) end
            self:addChild(e)
            return e
        end
        self.rows = { top + 4, top + 36, top + 68, top + 100, top + 132 }
        self.url = entry(self.rows[1], c.url or A.PROVIDERS[1].url, false, nil)
        self.key = entry(self.rows[2], "", true, c.hasKey and tr("KeyKept", "A key is saved. Leave empty to keep it.") or tr("KeyPaste", "Paste your key here (Ctrl+V)"))
        self.model = entry(self.rows[3], c.model or "", false, tr("ModelHint", "e.g. deepseek/deepseek-chat or a :free model"))
        local function btn(bx, by, bw, label, tipText, f, accent)
            local b = T.button(self, bx, by, bw, rowH, label, self, f, accent)
            b.tooltip = tipText
            return b
        end
        self.provBtn = btn(x, self.rows[4], 150, tr("BtnProvider", "Pick a provider"), tr("TipProvider", "Fills in the address for a known provider. Hover each one for what it's like."),
            function() K.providerMenu(self) end)
        self.bgBtn = btn(x + 160, self.rows[4], 170, "", tr("TipBg", "Only replies to me: only answers to you use the cloud (cheapest). Everything: people talking to each other, gossip, memories and radio news too (richest, costs much more). Click to switch."),
            function() self.bg = self.bg == "cloud" and "off" or "cloud"; self:labels() end)
        self.capBtn = btn(x + 340, self.rows[4], fw - 340, "", tr("TipCap", "Most cloud requests per hour, both helpers together. When it's reached, people use A-Life's own lines until the hour rolls over. Keeps the bill in check."),
            function() K.capMenu(self) end)
        local by = self.height - rowH - 12
        btn(10, by, 190, tr("BtnCloudSave", "Save and use the cloud"), tr("TipCloudSave", "Saves to alifeai_cloud.txt in Zomboid/Lua on this PC (never shared) and restarts the AI."),
            function() K.cloudSave(self, true) end, M.UIStyle and M.UIStyle.green or nil)
        btn(210, by, 190, tr("BtnCloudOff", "Turn the cloud off"), tr("TipCloudOff", "Back to the AI on your PC (Ollama). Your address, key and model stay saved for later."),
            function() K.cloudSave(self, false) end)
        btn(self.width - 110, by, 100, tr("BtnClose", "Close"), tr("TipClose", "Nothing is saved."), function() self:close() end)
        self:labels()
    end
    function F:labels()
        self.bgBtn:setTitle(self.bg == "cloud" and tr("BgCloud", "Everything: cloud") or tr("BgOff", "Only replies to me"))
        self.capBtn:setTitle(tr("CapLabel", "Max {1} an hour", self.cap))
    end
    function F:render()
        ALifeLLMTalkWindow.render(self)
        local labels = { tr("LUrl", "Address"), tr("LKey", "Key"), tr("LModel", "Model"), tr("LMore", "Options") }
        for i, l in ipairs(labels) do self:drawText(l, 12, self.rows[i] + 4, 0.84, 0.7, 0.38, 1, UIFont.Small) end
        local note = self.msg or tr("CloudNote", "What you say to people is sent to this provider. You pay them, not us. Your key stays on this PC.")
        local col = self.msg and { 0.92, 0.45, 0.35 } or { 0.6, 0.6, 0.62 }
        self:drawText(note, 12, self.rows[5] + 4, col[1], col[2], col[3], 1, UIFont.Small)
        local err = K.cloudErr(A.last and A.last.cloud or nil)
        if err then self:drawText(tr("CloudLast", "Last try: {1}", err), 12, self.rows[5] + 24, 0.92, 0.45, 0.35, 1, UIFont.Small) end
    end
    function F:close() ALifeLLMTalkWindow.close(self); if K.cloudWin == self then K.cloudWin = nil end end
    K.cloudWin = T.open(win)
    return K.cloudWin
end
function K.providerMenu(form)
    local cm = ISContextMenu.get(0, getMouseX(), getMouseY())
    for _, p in ipairs(A.PROVIDERS) do
        local o = cm:addOption(p.name, nil, function() form.url:setText(p.url) end)
        tip(o, p.what .. " <LINE> " .. p.url)
    end
end
function K.capMenu(form)
    local cm = ISContextMenu.get(0, getMouseX(), getMouseY())
    for _, n in ipairs(A.CLOUD_CAPS) do
        local o = cm:addOption(n .. (n == 150 and (" " .. tr("Default", "(default)")) or "") .. (n == form.cap and " *" or ""), nil, function() form.cap = n; form:labels() end)
        tip(o, n <= 60 and tr("TipCapLow", "Cheap. Busy scenes run out fast.") or (n >= 600 and tr("TipCapHigh", "For Everything: cloud. Watch your bill.") or tr("TipCapMid", "Plenty for replies to you.")))
    end
end

----------------------------------------------------------------------------------------------------------------
-- the tab
----------------------------------------------------------------------------------------------------------------
function K.addTab()
    if K.tabAdded then return true end
    local kit = M.winKit
    if type(kit) ~= "table" or not fn(M, "hubAddTab") or ALifeTalkHubPage == nil then return false end
    if M.settings.aiSetupTab == false then return false end
    local P = kit.page("ALifeTalkAISetupPage", "AI", "ai",
        tr("TipTab", "<SIZE:medium> AI <LINE> <SIZE:small> Set up the AI that lets people answer in their own words. Go top to bottom; each step turns green. The AI is optional: without it, plain commands and A-Life's own lines still work."))
    function P:text() local ok, t = pcall(K.text); return ok and t or ("AI: " .. tostring(t)) end
    function P:actions() return K.actions(kit.menuAt) end
    function P:refresh()
        K.ask()
        ALifeTalkHubPage.refresh(self)
        local sig = {}
        for _, a in ipairs(K.actions(kit.menuAt)) do sig[#sig + 1] = a.label end
        sig = table.concat(sig, "|")
        if sig ~= self.sig then self.sig = sig; self:buildButtons(); self:layout() end
    end
    function P:layoutMore(top, by)
        self.barY = by - 16
        pcall(function() self.body:setHeight(math.max(40, self.body:getHeight() - 16)) end)
    end
    -- the download bar
    function P:render()
        ALifeTalkHubPage.render(self)
        local s = A.last
        local job = type(s) == "table" and s.job or nil
        if job and job.state == "running" and (job.action == "pull" or job.action == "get_ollama") and self.barY then
            local x, w = 10, self.width - 20
            local pct = math.max(0, math.min(100, tonumber(job.progress) or 0))
            self:drawRect(x, self.barY, w, 8, 0.6, 0.15, 0.15, 0.17)
            self:drawRect(x, self.barY, math.floor(w * pct / 100), 8, 0.9, 0.45, 0.85, 0.45)
        end
    end
    M.hubAddTab({ id = "ai", label = "AI", class = "ALifeTalkAISetupPage",
        open = function() K.ask(); return kit.openPage(P, "winAISetup") end, ref = function() return M.winAISetup end }, "settings")
    if type(M.winHelp) == "table" then
        table.insert(M.winHelp, { "AI setup", "The AI tab walks you through it: the helper, Ollama, a model, a test reply, or a cloud AI instead. Open the AI folder takes you to Setup.cmd. Talk key, AI wait, language and voice are set there too. Hover any button for more. Doctor check makes one file for bug reports." })
    end
    if type(M.settingRows) == "table" then
        local have = false
        for _, r in ipairs(M.settingRows) do if r[1] == "aiSetupTab" then have = true end end
        if not have then M.settingRows[#M.settingRows + 1] = { "aiSetupTab", "AI tab in the A-Life window (AI setup)" } end
    end
    K.tabAdded = true
    return true
end
function K.install()
    pcall(K.addTab)
    print(TAG .. " ready v" .. K.VERSION .. ": AI tab " .. (K.tabAdded and "on" or "OFF") .. ", slow above "
        .. tostring(A.setting("aiSlowMs")) .. " ms, " .. tostring(#A.KNOWN) .. " known-good models")
end

----------------------------------------------------------------------------------------------------------------
-- 0.8.12 (Rock List 2): the AI status light over A-Life's talk window: "AI ready / slow / warming up / down / off" and
-- the model. Nothing at all when the AI was never set up (it's optional). Reads the files every 3 s, only while the
-- talk window is open. Setting aiStatusLight.
----------------------------------------------------------------------------------------------------------------
K.LIGHT = { ready = { "AI ready", 0.45, 0.85, 0.45 }, slow = { "AI slow", 0.95, 0.6, 0.3 }, warming = { "AI warming up", 0.95, 0.8, 0.35 },
    down = { "AI down", 0.92, 0.45, 0.35 }, paused = { "AI turned off", 0.6, 0.6, 0.62 }, off = { "AI off (helper not running)", 0.6, 0.6, 0.62 } }
function K.lightText(s)
    local word = A.summary(s)
    local l = K.LIGHT[word]
    if l == nil then return nil end
    local text = tr("Light_" .. word, l[1])
    if (word == "ready" or word == "slow" or word == "warming") and type(s) == "table" and s.modelName then
        text = text .. "  -  " .. short(s.modelName)
    end
    return text, l[2], l[3], l[4]
end
function K.lightDraw()
    if A.setting("aiStatusLight") == false then return end
    local WT = ALifeWindowTalk
    if not fn(WT, "window") then return end
    local ok, win = pcall(WT.window)
    if not ok or win == nil then return end
    local t = nowMs()
    if t - (K.lightAskAt or 0) > 3000 then K.lightAskAt = t; K.ask() end
    local text, r, g, b = K.lightText(A.last)
    if text == nil then return end
    local x, y = 0, 0
    pcall(function() x, y = win:getAbsoluteX(), win:getAbsoluteY() end)
    local tm = getTextManager()
    local fh = 16
    pcall(function() fh = tm:getFontHeight(UIFont.Small) end)
    tm:DrawString(UIFont.Small, x + 6, math.max(0, y - fh - 2), text, r, g, b, 0.95)
end

----------------------------------------------------------------------------------------------------------------
-- 0.8.12 (Rock List 2): one letter, once ever, for a player who hasn't set the AI up: where the AI tab is. Never when
-- the AI already works; never again after (ui prefs). Settings aiFirstLetter, aiFirstLetterSec.
----------------------------------------------------------------------------------------------------------------
function K.firstLetterDue(s, uiSeen)
    if A.setting("aiFirstLetter") == false or uiSeen then return false end
    if type(s) ~= "table" then return false end
    local word = A.summary(s)
    return word ~= "ready" and word ~= "slow" and word ~= "warming" and word ~= "paused"
end
function K.firstLetterTick()
    if K.firstDone then return end
    local t = nowMs()
    K.startedAt = K.startedAt or t
    if t - K.startedAt < (tonumber(A.setting("aiFirstLetterSec")) or 90) * 1000 then return end
    K.firstDone = true
    local seen = M.uiPref and M.uiPref("ai.firstLetter", false) or false
    local s = A.state(playerOf())
    if M.uiSet then M.uiSet("ai.firstLetter", true) end
    if not K.firstLetterDue(s, seen) then return end
    local p = playerOf()
    if p then
        pcall(ALifeLetter, p, tr("FirstLetter", "A-Life NPC Overhaul: people can answer in their own words with a free AI on your PC. To set it up: right-click > A-Life... > AI tab, top to bottom. Optional: everything works without it."), 150, 200, 240)
    end
    ALifeHealth.note(TAG, "first-run letter: AI tab")
end

if type(Events) == "table" and Events.OnGameStart ~= nil then Events.OnGameStart.Add(function() pcall(K.install) end) end
if type(Events) == "table" and Events.OnPostUIDraw ~= nil and ALifeHealth and ALifeHealth.add then
    ALifeHealth.add(Events.OnPostUIDraw, "ALifeAISetupLight", function() pcall(K.lightDraw) end)
end
if type(Events) == "table" and Events.OnTick ~= nil and ALifeHealth and ALifeHealth.add then
    ALifeHealth.add(Events.OnTick, "ALifeAISetupLetter", function() if not K.firstDone then pcall(K.firstLetterTick) end end)
end
