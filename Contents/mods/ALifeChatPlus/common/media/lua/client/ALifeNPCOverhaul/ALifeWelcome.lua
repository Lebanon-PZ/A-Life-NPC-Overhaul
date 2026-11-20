-- A-Life NPC Overhaul pre-1.0 (trip-ups, docs/PLAN-TRIPUPS.md): FIRST STEPS.
-- (This file was empty since 0.4.0, when the first-launch AI popup went. It is not that popup: no AI talk here.)
-- Once per player (alifeai_ui.txt on this machine), a letter with what a new player needs: right-click > A-Life,
-- how to talk, where the keys are, the Help tab. Two more one-time tips:
--   * hover read set to "only while the key is held" with no key bound (it can never show) -> where to bind it
--   * the first line typed while the AI is off -> plain orders still work, Help > Commands lists them.
--     Once ever, not once a session: the AI is optional and the mod never nags about it.
-- All three are off with Settings > "A tip the first time you open each tab" (firstTips); "Show the tips again" on the
-- Help tab brings them back. Client only: each player sees their own, in MP too.
require "ALifeNPCOverhaul/AA_Side"
require "ALifeLLMTalk/ALifeLLMTalk_Main"
local M = ALifeLLMTalk
if type(M) ~= "table" then return end
ALifeWelcome = ALifeWelcome or {}
local W = ALifeWelcome
W.VERSION = "pre-1.0"
W.IDS = { "welcome", "hoverkey", "noai" }
W.metrics = W.metrics or { shown = 0 }
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function tr(key, english) if type(ALifeTr) == "function" then return ALifeTr("IGUI_ALCP_" .. key, english) end return english end
local function tipsOn() return type(M.settings) ~= "table" or M.settings.firstTips ~= false end
local function seen(id)
    if not fn(M, "uiPref") then return true end -- no place to remember it: never show (it would show every load)
    local v = M.uiPref("tip." .. id, false)
    return v == true or v == "true"
end
local function mark(id) if fn(M, "uiSet") then M.uiSet("tip." .. id, true) end end
local function player() return type(ALifeSide) == "table" and fn(ALifeSide, "localPlayer") and ALifeSide.localPlayer() or nil end

W.TEXT = {
    welcome = "A-Life NPC Overhaul: right-click > A-Life opens the quick wheel for whoever (or wherever) you point at. "
        .. "Talk: walk up to someone and use the chat key. Keys: Options > Mods > A-Life NPC Overhaul (none are set at first). "
        .. "Everything else, and Help: the A-Life window, on the wheel.",
    hoverkey = "Reading people by hovering is set to 'only while the key is held', but no key is bound. "
        .. "Bind one: Options > Mods > A-Life NPC Overhaul > Hover: read people.",
    noai = "The AI is off, so people answer in A-Life's own lines. Plain orders still work: Help > Commands lists them. "
        .. "Want free talk? A-Life window > AI tab.",
}
-- one tip, once; true = shown now
function W.tip(id, p)
    if not tipsOn() or seen(id) or W.TEXT[id] == nil then return false end
    p = p or player()
    if p == nil then return false end
    local key = "Tip_" .. id
    local text = tr(key, W.TEXT[id])
    local ok, shown = false, false
    if type(ALifeLetter) == "function" then ok, shown = pcall(ALifeLetter, p, text, 242, 217, 166) end
    if not ok or shown == false then return false end
    mark(id)
    W.metrics.shown = W.metrics.shown + 1
    return true
end
-- the hover key: unbound while "only while held" is on
function W.hoverKeyMissing()
    local cues = ALifeCues
    local keyOnly = false
    if fn(cues, "setting") then keyOnly = cues.setting("hoverKeyOnly") == true end
    if not keyOnly then return false end
    local opt = type(ALifeRadial) == "table" and ALifeRadial.hoverKeyOpt or nil
    if opt == nil or not fn(opt, "getValue") then return true end
    local ok, k = pcall(opt.getValue, opt)
    return not ok or k == nil or k == 0
end
function W.firstLook(p)
    local a = W.tip("welcome", p)
    local b = false
    if W.hoverKeyMissing() then b = W.tip("hoverkey", p) end
    return a, b
end
-- the first line typed with the AI off (Main's input log: "AI talk off" / "AI bridge offline")
W.NOAI = { ["AI talk off"] = true, ["AI bridge offline"] = true }
function W.onInput(path, why)
    if path == "A-Life" and W.NOAI[tostring(why)] then return W.tip("noai") end
    return false
end
local function wrapInput()
    if not fn(M, "inputNote") or M.inputNote == W._wrapped then return false end
    local orig = M.inputNote
    W._wrapped = function(text, path, why, ...)
        pcall(W.onInput, path, why)
        return orig(text, path, why, ...)
    end
    M.inputNote = W._wrapped
    return true
end
wrapInput()

if type(Events) == "table" and Events.OnGameStart then
    Events.OnGameStart.Add(function()
        wrapInput() -- again: a later module may have replaced it
        if Events.EveryOneMinute == nil then return end
        local ticks, done = 0, false
        local function look()
            if done then return end
            ticks = ticks + 1
            if ticks < 3 then return end -- letters and the hub are up by now
            done = true
            pcall(W.firstLook)
        end
        Events.EveryOneMinute.Add(look)
    end)
end
print("[ALifeWelcome] ready " .. W.VERSION .. ": first-steps letter, hover key + AI-off tips (once each)")
