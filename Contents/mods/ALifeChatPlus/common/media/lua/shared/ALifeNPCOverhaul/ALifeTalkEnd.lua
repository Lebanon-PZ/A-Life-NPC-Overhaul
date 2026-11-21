-- A-Life NPC Overhaul 0.8.3 step 2: THEY END IT. When an NPC walks out of a talk (the AI chose to leave after you
-- were rude, or they now can't stand you), the conversation really ends:
--   * client: the talk window shows A-Life's own "They ended the conversation." and closes a moment later
--     (A-Life's own panel.closeAt, the same thing A-Life does when its own talk ends);
--   * server: A-Life's own refusal window is set (TalkSocial row.ru, as long as A-Life's Talk_RefuseMinutes), so
--     for a while they answer with A-Life's own "Go away, I'm not in the mood" lines;
--   * keep pushing inside that window and it costs you with them (talkPushCost each time, at most talkPushMax).
-- You saying goodbye closes the window too, with no hard feelings (no refusal).
-- Multiplayer-ready: the client sends { uid, refuse } / { uid } through ALifeCmd; the server checks the record and
-- the refusal window itself. Settings: talkEndClose, talkEndCloseMs, talkEndRefuse, talkPushCost, talkPushMax.
require "ALifeNPCOverhaul/AA_Side"
require "ALifeNPCOverhaul/ALifeCmd"

ALifeTalkEnd = ALifeTalkEnd or {}
local E = ALifeTalkEnd
local TAG = "[ALifeTalkEnd]"
E.VERSION = ALifeSide.MOD_VERSION
E.metrics = E.metrics or { ended = 0, refused = 0, closed = 0, pushed = 0, cost = 0 }

local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function log(msg) print(TAG .. " " .. tostring(msg)) end

E.DEFAULTS = {
    talkEndClose = true,    -- the talk window closes when they end it (or you say goodbye)
    talkEndCloseMs = 3600,  -- how long the window stays open after their parting line (A-Life's own value)
    talkEndRefuse = true,   -- after they end it they won't talk for a while (A-Life's Talk_RefuseMinutes)
    talkPushCost = 2,       -- each time you keep at them inside that time, how much they like you less (0 = off)
    talkPushMax = 5,        -- most times pushing costs you per refusal (so spamming can't wreck it completely)
}
function E.setting(key)
    local m = ALifeLLMTalk
    local v = nil
    if type(m) == "table" and type(m.settings) == "table" then v = m.settings[key] end
    if v == nil then v = E.DEFAULTS[key] end
    return v
end

----------------------------------------------------------------------------------------------------------------
-- server
----------------------------------------------------------------------------------------------------------------
local function recordOf(uid)
    local reg = PA() and PA().ActorRegistry or nil
    if not fn(reg, "read") then return nil end
    local ok, rec = pcall(reg.read, uid)
    if ok and type(rec) == "table" then return rec end
    return nil
end

-- the row A-Life keeps for this player in their memory (TalkSocial), read-only copy
local function socialRow(record, player)
    local S = PA() and PA().TalkSocial or nil
    if not (fn(S, "keyOf") and fn(S, "rowOf") and fn(S, "hours")) then return nil, nil, nil end
    local key = S.keyOf(player)
    if key == nil then return nil, nil, nil end
    return S.rowOf(record, key), key, S
end

function E.refusing(record, player)
    local row, _, S = socialRow(record, player)
    if type(row) ~= "table" or row.ru == nil then return false end
    return S.hours() < (tonumber(row.ru) or 0)
end

-- { uid, refuse }: they ended it (refuse = true) or you said goodbye (refuse = false)
function E.serverEnd(player, args)
    if type(args) ~= "table" or type(args.uid) ~= "string" or args.uid == "" then return false end
    E.metrics.ended = E.metrics.ended + 1
    if args.refuse ~= true or E.setting("talkEndRefuse") == false then return true end
    local record = recordOf(args.uid)
    if record == nil then return false end
    local S = PA().TalkSocial
    if not (fn(S, "keyOf") and fn(S, "hours") and fn(S, "config") and fn(S, "copy") and fn(S, "rowOf")
            and fn(S, "put") and fn(S, "write")) then
        log("A-Life TalkSocial missing - no refusal window")
        return false
    end
    local key = S.keyOf(player)
    if key == nil then return false end
    local now = S.hours()
    local cfg = S.config()
    local ok = S.write(record.uid, function(memory)
        local row = S.copy(S.rowOf({ memory = memory }, key))
        row.ru = now + (tonumber(cfg.refuseHours) or 1)
        row.an, row.aat = math.max(2, tonumber(row.an) or 0), now
        row.ct = 0
        row.acpPush = 0
        S.put(memory, key, row)
    end)
    if ok then E.metrics.refused = E.metrics.refused + 1 end
    log((ok and "refusal set" or "refusal NOT set") .. " for " .. tostring(args.uid) .. " (" .. tostring(math.floor((tonumber(cfg.refuseHours) or 1) * 60)) .. " game min)")
    return ok
end

-- { uid }: you kept talking while they refuse -> costs opinion (server checks the refusal really is on)
function E.serverPushed(player, args)
    if type(args) ~= "table" or type(args.uid) ~= "string" or args.uid == "" then return false end
    local cost = tonumber(E.setting("talkPushCost")) or 0
    if cost <= 0 then return false end
    local record = recordOf(args.uid)
    if record == nil or not E.refusing(record, player) then return false end
    local row, key, S = socialRow(record, player)
    local n = tonumber(row and row.acpPush) or 0
    if n >= (tonumber(E.setting("talkPushMax")) or 0) then return false end
    local opinion = PA().NpcOpinion
    if not fn(opinion, "adjust") or (fn(opinion, "enabled") and not opinion.enabled()) then return false end
    local ok = opinion.adjust(record, player, -cost, "You kept at them after they ended it.", function(memory)
        local r = S.copy(S.rowOf({ memory = memory }, key))
        r.acpPush = n + 1
        S.put(memory, key, r)
    end)
    if ok then
        E.metrics.pushed = E.metrics.pushed + 1
        E.metrics.cost = E.metrics.cost + cost
    end
    return ok
end

if fn(ALifeCmd, "onServer") then
    ALifeCmd.onServer("talkEnd", function(player, args) return E.serverEnd(player, args) end)
    ALifeCmd.onServer("talkPushed", function(player, args) return E.serverPushed(player, args) end)
end

----------------------------------------------------------------------------------------------------------------
-- client
----------------------------------------------------------------------------------------------------------------
-- the open talk window, if it is with this uid
function E.windowFor(uid)
    local pa = PA()
    if pa == nil then return nil end
    local win = nil
    local surface = pa.TalkSurface
    if fn(surface, "windowOf") then
        local ok, w = pcall(surface.windowOf, nil)
        if ok then win = w end
    elseif type(pa.TalkMenu) == "table" then
        win = pa.TalkMenu.instance
        if win ~= nil and fn(win, "isVisible") and not win:isVisible() then win = nil end
    end
    if win == nil or win.uid == nil or tostring(win.uid) ~= tostring(uid) then return nil end
    return win
end

-- called on the client when a reply ends the talk. refuse = they walked out; false = you said goodbye.
function E.ended(player, uid, refuse, now)
    if uid == nil then return end
    uid = tostring(uid)
    if E.setting("talkEndClose") ~= false then
        local win = E.windowFor(uid)
        if win ~= nil and win.closeAt == nil then
            if refuse == true and fn(win, "append") then
                local menu = PA().TalkMenu
                local msg = type(menu) == "table" and type(menu.messages) == "table" and menu.messages.talk_ended or nil
                if type(msg) == "string" then
                    local T = PA().Text -- A-Life's own translation wrapper (TalkMenu does Text.ui(Menu.messages[reason]))
                    if fn(T, "ui") then pcall(function() msg = T.ui(msg) end) end
                    pcall(win.append, win, msg, "A-LIFE")
                end
            end
            win.closeAt = (now or getTimestampMs()) + (tonumber(E.setting("talkEndCloseMs")) or 3600)
            E.metrics.closed = E.metrics.closed + 1
        end
    end
    if fn(ALifeCmd, "send") then ALifeCmd.send(player, "talkEnd", { uid = uid, refuse = refuse == true }) end
    -- 0.8.3 step 6: the visit is over; it is remembered with how it ended
    local m = ALifeLLMTalk
    if fn(m, "visitEnd") then pcall(m.visitEnd, uid, player, refuse == true and "walked" or "bye") end
end

-- called on the client when A-Life refused your line because they ended it earlier
function E.pushed(player, uid)
    if uid == nil or not fn(ALifeCmd, "send") then return end
    ALifeCmd.send(player, "talkPushed", { uid = tostring(uid) })
end

log("ready v" .. E.VERSION .. ": they end it (window closes, A-Life refusal window, pushing costs " .. tostring(E.DEFAULTS.talkPushCost) .. ")")
