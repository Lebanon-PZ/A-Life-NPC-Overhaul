-- A-Life NPC Overhaul 0.7.0: QUALITY OF LIFE (the parts behind the A-Life window).
--   * EVENT LOG: the camp's own notes, immersive (no numbers): stores getting thin, new faces, losses, groups growing
--     warmer or colder toward you, traders passing through, someone not seen in a while.
--   * WHY NOT: when someone refuses (to come along, to take a job), you're told why in plain words, and it goes in
--     their journal.
--   * NAMED PLACES: right-click the ground > "Name this place...". It goes on your map; people can be sent there to
--     meet up or to hold it (they walk there for real; meet ends when you get there or after a day).
--   * ORDERS: one list of orders used by the quick-order bar, bulk orders and the People page.
--   * WIDGET + QUICK ORDERS BAR: small panels you can drag anywhere; right-click either for its settings (what it
--     shows, size, see-through, lock, auto-hide when all is well). Saved in Zomboid/Lua/alifeai_ui.txt.
-- Performance: the log and place orders run every 2 s (place orders) or every game hour (stores); the widget reads
-- the camp every 10 s (the camp read itself is cached for 2 minutes).
-- pre-1.0 MP: split. This file = the logic (log, why not, places, orders, UI prefs); ALifeTalk_QoL_UI.lua (client) =
-- the notice log, the widget, the quick-order bar, the place menu.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalk_QoL") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
local M = ALifeLLMTalk
if type(M) ~= "table" then return end

local function log(msg) if M.log then M.log("qol: " .. tostring(msg)) end end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
local function now() return type(getTimestampMs) == "function" and getTimestampMs() or 0 end
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function d2(ax, ay, bx, by) return (ax - bx) ^ 2 + (ay - by) ^ 2 end
local function playerOf() local p = nil; pcall(function() p = ALifeSide.you() end); return p end
local function tr(k, en, ...)
    if ALifeTr then return ALifeTr("IGUI_ALCP_" .. k, en, ...) end
    local a = { ... }
    return (string.gsub(en, "{(%d)}", function(i) return tostring(a[tonumber(i)] or "") end))
end
-- pre-1.0 MP (P4): the event log, named places and place orders live where the world is. An MP client reads a copy
-- the server shares ("ALifeChatPlus_QoLView"); its windows change them through exposed calls (end of file).
M.QOL_VIEW = "ALifeChatPlus_QoLView"
local function mpClient() return type(ALifeSide) == "table" and ALifeSide.mpClient() end
local function mpServer() return type(ALifeSide) == "table" and ALifeSide.mpServer() end
local function qolTouch() if mpServer() and type(ALifeRemote) == "table" then ALifeRemote.touch(M.QOL_VIEW) end end
local function store()
    if mpClient() then
        local v = type(ALifeRemote) == "table" and ALifeRemote.shared(M.QOL_VIEW) or nil
        local st = type(v) == "table" and v or (M._qolEmpty or {})
        if type(v) ~= "table" then M._qolEmpty = st end
        st.elog = type(st.elog) == "table" and st.elog or {}
        st.places = type(st.places) == "table" and st.places or {}
        st.plOrders = type(st.plOrders) == "table" and st.plOrders or {}
        st.qolFlags = type(st.qolFlags) == "table" and st.qolFlags or {}
        return st
    end
    local st = fn(M, "nbStore") and M.nbStore() or (M._qolMem or {})
    M._qolMem = st
    st.elog = type(st.elog) == "table" and st.elog or {}
    st.places = type(st.places) == "table" and st.places or {}
    st.plOrders = type(st.plOrders) == "table" and st.plOrders or {}
    st.qolFlags = type(st.qolFlags) == "table" and st.qolFlags or {}
    return st
end
M.qolStore = store
-- the name you know someone by
function M.qolName(uid)
    local n = nil
    local p = playerOf()
    if fn(M, "shownName") and p then pcall(function() n = M.shownName(tostring(uid), p) end) end
    if (n == nil or n == "") and fn(M, "pb") then local e = M.pb(tostring(uid), false); n = type(e) == "table" and e.name or nil end
    return tostring(n or "someone")
end

----------------------------------------------------------------------------------------------------------------
-- event log
----------------------------------------------------------------------------------------------------------------
M.elCap = M.elCap or 300
function M.elAdd(kind, text, h)
    if M.settings.eventLog == false or text == nil or text == "" then return end
    local L = store().elog
    h = h or hours()
    local last = L[#L]
    if last and last.t == text and h - (tonumber(last.h) or -1e9) < 12 then return end -- the same note twice in half a day
    L[#L + 1] = { h = h, k = kind, t = tostring(text) }
    while #L > M.elCap do table.remove(L, 1) end
end
-- newest first
function M.elRows(n)
    local L, out = store().elog, {}
    for i = #L, math.max(1, #L - (n or 1e9) + 1), -1 do out[#out + 1] = L[i] end
    return out
end
local function dayText(h)
    if fn(M, "gameDate") then local ok, s = pcall(M.gameDate, h); if ok and s then return tostring(s) end end
    return "Day " .. (math.floor((tonumber(h) or 0) / 24) + 1)
end
M.qolDay = dayText
function M.elText(n)
    local rows = M.elRows(n)
    if #rows == 0 then return tr("ElogEmpty", "Nothing written down yet. The camp's notes fill in as things happen.") end
    local out, lastDay = {}, nil
    for _, r in ipairs(rows) do
        local d = dayText(r.h)
        if d ~= lastDay then out[#out + 1] = " <LINE> <RGB:0.84,0.7,0.38> " .. d .. " <RGB:0.87,0.88,0.9> <LINE> "; lastDay = d end
        out[#out + 1] = tostring(r.t) .. " <LINE> "
    end
    return table.concat(out)
end
-- how full the stores feel (food items per mouth, never shown as a number)
function M.qolFoodWord(per)
    per = tonumber(per)
    if per == nil then return nil end
    if per >= 10 then return tr("FoodPlenty", "plenty") elseif per >= 5 then return tr("FoodOk", "enough for now")
    elseif per >= 2 then return tr("FoodThin", "getting thin") end
    return tr("FoodLow", "running low")
end
local function foodBand(per) per = tonumber(per) or 0; if per >= 10 then return 4 elseif per >= 5 then return 3 elseif per >= 2 then return 2 end return 1 end
function M.elHourly()
    local p = playerOf()
    if mpServer() and fn(M, "homePlayer") then p = M.homePlayer() end -- MP: the camp's player
    if p == nil or not fn(M, "baseState") then return end
    local okS, bs = pcall(M.baseState, p)
    if not okS or type(bs) ~= "table" then return end
    local f = store().qolFlags
    local band = foodBand(bs.foodPer)
    if f.foodBand ~= nil and band ~= f.foodBand then
        if band == 1 then M.elAdd("stores", tr("ElogFoodLow", "Food is running low."))
        elseif band == 2 and f.foodBand > 2 then M.elAdd("stores", tr("ElogFoodThin", "The stores are getting thin."))
        elseif band >= 3 and f.foodBand <= 2 then M.elAdd("stores", tr("ElogFoodBack", "The pantry's in better shape again.")) end
    end
    f.foodBand = band
    local n = tonumber(bs.settlers) or 0
    if f.people ~= nil and n < f.people and n == 0 then M.elAdd("people", tr("ElogEmptyCamp", "The camp is empty now.")) end
    f.people = n
end

----------------------------------------------------------------------------------------------------------------
-- why not: refusals in plain words
----------------------------------------------------------------------------------------------------------------
M.qolRoleWhy = { guard = "too scared to stand guard", cook = "says they're no cook", medic = "doesn't trust their own hands with that",
    builder = "says they're no builder", farmer = "doesn't know the first thing about farming", shepherd = "won't look after the animals" }
function M.whyNot(uid, what, reason)
    if M.settings.whyNot == false then return end
    reason = tostring(reason or "")
    reason = string.gsub(reason, ";.*$", "") -- never the numbers
    reason = string.gsub(reason, "%s*%(.-%d.-%)", "")
    local name = M.qolName(uid)
    local text = tr("WhyNot", "{1} won't {2}: {3}.", name, what, reason)
    if mpServer() then
        if type(ALifeOut) == "table" then ALifeOut.toast(ALifeSide.cur, text) end
    elseif fn(M, "momToast") then pcall(M.momToast, text) end
    if fn(M, "histAdd") then pcall(M.histAdd, tostring(uid), "party", "Wouldn't " .. tostring(what) .. ": " .. reason) end
end

----------------------------------------------------------------------------------------------------------------
-- named places
----------------------------------------------------------------------------------------------------------------
function M.plAdd(name, x, y, z)
    name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then return nil end
    local P = store().places
    local id = "p" .. math.floor(hours() * 100) .. "_" .. math.floor(x) .. "_" .. math.floor(y)
    local pl = { id = id, name = string.sub(name, 1, 40), x = math.floor(x), y = math.floor(y), z = math.floor(z or 0), h = hours() }
    P[#P + 1] = pl
    M.jnQueue = M.jnQueue or {}
    M.jnQueue[#M.jnQueue + 1] = { text = pl.name, x = pl.x, y = pl.y }
    if fn(M, "jnFlush") then pcall(M.jnFlush) end
    M.elAdd("place", tr("ElogPlace", "We started calling a spot \"{1}\".", pl.name))
    if mpServer() and ALifeSide.cur ~= nil and type(ALifeOut) == "table" then -- MP: the window that asked gets the word
        ALifeOut.toast(ALifeSide.cur, tr("PlaceNamed", "Marked \"{1}\" on your map.", pl.name))
    end
    qolTouch()
    return pl
end
function M.plGet(id) for _, pl in ipairs(store().places) do if pl.id == id then return pl end end return nil end
function M.plRemove(id)
    local P = store().places
    for i = #P, 1, -1 do if P[i].id == id then table.remove(P, i) end end
    for uid, o in pairs(store().plOrders) do if o.place == id then M.plRecall(uid) end end
    qolTouch()
end
function M.plNear(x, y, r)
    local best, bd = nil, (r or 8) ^ 2
    for _, pl in ipairs(store().places) do local d = d2(pl.x, pl.y, x, y); if d <= bd then best, bd = pl, d end end
    return best
end
-- the names you gave places, for NPCs to use (the AI's prompt can read these)
function M.plNames() local out = {}; for _, pl in ipairs(store().places) do out[#out + 1] = pl.name end; return out end

local function patch() return type(ALifeTalkPatch) == "table" and ALifeTalkPatch or nil end
-- send someone to a named place: "meet" (wait there until you come, or a day) or "hold" (until you call them back)
function M.plOrder(uid, placeId, mode)
    uid = tostring(uid)
    local pl = M.plGet(placeId)
    if pl == nil then return false end
    local reg = PA().ActorRegistry
    local r = fn(reg, "read") and reg.read(uid) or nil
    if r == nil or r.lifecycle == "dead" then return false end
    if fn(M, "partyIsMember") and M.partyIsMember(uid, playerOf()) and fn(M, "partyCommand") then pcall(M.partyCommand, uid, "hold", playerOf()) end
    store().plOrders[uid] = { place = pl.id, mode = mode == "hold" and "hold" or "meet", at = hours() }
    qolTouch()
    if fn(M, "histAdd") then pcall(M.histAdd, uid, "party", (mode == "hold" and "Sent to hold " or "Sent to meet you at ") .. pl.name) end
    return true
end
function M.plRecall(uid)
    uid = tostring(uid)
    store().plOrders[uid] = nil
    local P = patch()
    local c = P and P.own and P.own.claims and P.own.claims[uid] or nil
    if c and c.kind == "party" and c.spec and c.spec.alcpPlace and fn(P, "release") then pcall(P.release, uid, "recalled") end
    if fn(M, "lvCancel") then M.lvCancel(uid) end
end
function M.plOrderOf(uid) return store().plOrders[tostring(uid)] end
M.plCfg = M.plCfg or { walkTiles = 120, meetEndH = 24, tickMs = 2000, holdRadius = 3 }
local plLast = -1e12
function M.plTick()
    local t = now()
    if t - plLast < M.plCfg.tickMs then return end
    plLast = t
    local orders = store().plOrders
    local any = false
    for _ in pairs(orders) do any = true; break end
    if not any then return end
    local reg = PA().ActorRegistry
    if not fn(reg, "read") then return end
    local p = playerOf()
    local px, py = nil, nil
    pcall(function() px, py = p:getX(), p:getY() end)
    local h = hours()
    local ids = {}
    for uid in pairs(orders) do ids[#ids + 1] = uid end
    for _, uid in ipairs(ids) do
        local o = orders[uid]
        local pl = M.plGet(o.place)
        if mpServer() and pl ~= nil then -- MP: "you came" = any online player reaching the place (the nearest one is you)
            p = ALifeSide.nearest(pl.x, pl.y)
            px, py = nil, nil
            if p ~= nil then pcall(function() px, py = p:getX(), p:getY() end) end
        end
        local r = reg.read(uid)
        if pl == nil or r == nil or r.lifecycle == "dead" then orders[uid] = nil
        elseif o.mode == "meet" and (h - (tonumber(o.at) or h) > M.plCfg.meetEndH or (px and d2(px, py, pl.x, pl.y) < 36)) then
            M.plRecall(uid) -- you came (or a day went by): the meet-up is over
        else
            local away = fn(M, "lvIsAway") and M.lvIsAway(uid)
            if r.lifecycle == "active" then
                local sh = nil
                pcall(function() sh = PA().Talk.shellFor(uid) end)
                local x, y = nil, nil
                pcall(function() x, y = sh:getX(), sh:getY() end)
                if x and d2(x, y, pl.x, pl.y) <= M.plCfg.walkTiles ^ 2 then
                    if away then M.lvCancel(uid) end
                    local P = patch()
                    if P and fn(P, "claim") then
                        pcall(P.claim, uid, "party", { mode = "hold", anchor = { x = pl.x, y = pl.y, z = pl.z }, radius = M.plCfg.holdRadius,
                            ms = 60000, player = p, alcpPlace = pl.id })
                    end
                elseif x and not away and fn(M, "lvSend") then
                    pcall(M.lvSend, uid, { tx = pl.x, ty = pl.y, final = { x = pl.x, y = pl.y, z = pl.z }, tag = "place" })
                end
            elseif not away and type(r.worldPosition) == "table" and d2(r.worldPosition.x, r.worldPosition.y, pl.x, pl.y) > 900 and fn(M, "lvSend") then
                pcall(M.lvSend, uid, { tx = pl.x, ty = pl.y, final = { x = pl.x, y = pl.y, z = pl.z }, tag = "place" })
            end
        end
    end
end


----------------------------------------------------------------------------------------------------------------
-- orders (quick bar, bulk, the People page)
----------------------------------------------------------------------------------------------------------------
local function camp(uid) return fn(M, "cpIsHome") and M.cpIsHome(tostring(uid), playerOf()) end
local function member(uid) return fn(M, "partyIsMember") and M.partyIsMember(tostring(uid), playerOf()) end
M.qoOrders = {
    { id = "follow", label = "Follow me", who = "person", ok = member, run = function(uid) return M.partyCommand(uid, "follow", playerOf()) end },
    { id = "wait", label = "Wait here", who = "person", ok = member, run = function(uid) return M.partyCommand(uid, "hold", playerOf()) end },
    { id = "guard", label = "Guard here", who = "person", ok = member, run = function(uid) return M.partyCommand(uid, "guard", playerOf()) end },
    { id = "home", label = "Go back to the base", who = "person", ok = member, run = function(uid) return M.partyCommand(uid, "base", playerOf()) end },
    { id = "recall", label = "Stand down (forget the place order)", who = "person", ok = function(uid) return M.plOrderOf(uid) ~= nil end, run = function(uid) M.plRecall(uid); return true end },
    { id = "posts", label = "To your posts!", who = "camp", ok = function() return fn(M, "alRaiseNow") end, run = function() return M.alRaiseNow("your order", playerOf()) end },
    { id = "clear", label = "All clear", who = "camp", ok = function() return fn(M, "alClear") end, run = function() return M.alClear(playerOf(), "your order") end },
    { id = "lights", label = "Lights out", who = "camp", ok = function() return fn(M, "alLightsOut") end, run = function() return M.alLightsOut(playerOf()) end },
    { id = "party", label = "Everyone with me: follow", who = "party", ok = function() return fn(M, "partyMembers") end, run = function()
        for _, m in ipairs(M.partyMembers(playerOf()) or {}) do pcall(M.partyCommand, type(m) == "table" and (m.uid or m) or m, "follow", playerOf()) end; return true end },
    { id = "partywait", label = "Everyone with me: wait here", who = "party", ok = function() return fn(M, "partyMembers") end, run = function()
        for _, m in ipairs(M.partyMembers(playerOf()) or {}) do pcall(M.partyCommand, type(m) == "table" and (m.uid or m) or m, "hold", playerOf()) end; return true end },
}
M.qoById = {}
for _, o in ipairs(M.qoOrders) do M.qoById[o.id] = o end
function M.qoRun(id, uid)
    local o = M.qoById[id]
    if o == nil then return false end
    local ok, res = pcall(o.run, uid)
    return ok and res ~= false
end
-- one order to many people; returns how many took it
function M.bulkOrder(uids, id, arg)
    if mpClient() then -- MP: one call per person to the server (a list can't cross); the answer comes back as toasts
        for _, uid in ipairs(uids or {}) do M.bulkOrder1(tostring(uid), id, arg) end
        return nil
    end
    local n = 0
    for _, uid in ipairs(uids or {}) do
        local ok = false
        if id == "role" then
            if fn(M, "cpSetRole") then local _, took = M.cpSetRole(uid, arg, playerOf()); ok = took ~= false end
        elseif id == "meet" or id == "hold" then ok = M.plOrder(uid, arg, id)
        else
            local o = M.qoById[id]
            if o and (o.ok == nil or o.ok(uid)) then ok = M.qoRun(id, uid) end
        end
        if ok then n = n + 1 end
    end
    return n
end

----------------------------------------------------------------------------------------------------------------
-- small saved UI settings (Zomboid/Lua/alifeai_ui.txt): key=value
----------------------------------------------------------------------------------------------------------------
M.uiPrefs = M.uiPrefs or nil
function M.uiPref(k, default)
    if M.uiPrefs == nil then
        M.uiPrefs = {}
        pcall(function()
            local r = getFileReader("alifeai_ui.txt", false)
            if r == nil then return end
            local line = r:readLine()
            while line do
                local a, b = string.match(line, "^([%w_%.]+)=(.*)$")
                if a then
                    if b == "true" then b = true elseif b == "false" then b = false elseif tonumber(b) then b = tonumber(b) end
                    M.uiPrefs[a] = b
                end
                line = r:readLine()
            end
            r:close()
        end)
    end
    local v = M.uiPrefs[k]
    if v == nil then return default end
    return v
end
function M.uiSet(k, v)
    M.uiPref(k)
    M.uiPrefs[k] = v
    pcall(function()
        local w = getFileWriter("alifeai_ui.txt", true, false)
        local keys = {}
        for kk in pairs(M.uiPrefs) do keys[#keys + 1] = kk end
        table.sort(keys)
        for _, kk in ipairs(keys) do w:write(kk .. "=" .. tostring(M.uiPrefs[kk]) .. "\r\n") end
        w:close()
    end)
end

----------------------------------------------------------------------------------------------------------------
-- install: wraps for the log and "why not", the place tick, the right-click entry, the panels
----------------------------------------------------------------------------------------------------------------
function M.qolInstall()
    if M._qolHooked then return true end
    M._qolHooked = true
    -- new faces
    if fn(M, "settleApply") then
        local orig = M.settleApply
        M.settleApply = function(l, ...)
            local res = orig(l, ...)
            if res and type(l) == "table" and type(l.record) == "table" then
                pcall(M.elAdd, "people", tr("ElogJoined", "{1} joined us.", M.qolName(l.record.uid)))
            end
            return res
        end
    end
    -- losses
    if fn(M, "cpOnDeath") then
        local orig = M.cpOnDeath
        M.cpOnDeath = function(body, uid, killer, ...)
            local was = uid and camp(uid)
            local res = orig(body, uid, killer, ...)
            if was then pcall(M.elAdd, "loss", tr("ElogLost", "We lost {1}.", M.qolName(uid))) end
            return res
        end
    end
    -- groups warming or cooling toward you (only groups you know of)
    if fn(M, "nbRep") and fn(M, "nbRepWord") then
        local orig = M.nbRep
        M.nbRep = function(b, d, why, ...)
            local before = type(b) == "table" and M.nbRepWord(b.rep) or nil
            local res = orig(b, d, why, ...)
            if type(b) == "table" and b.known and before then
                local after = M.nbRepWord(b.rep)
                if after ~= before then
                    pcall(M.elAdd, "groups", (tonumber(d) or 0) > 0 and tr("ElogWarmer", "{1} seem warmer toward us.", tostring(b.name))
                        or tr("ElogColder", "{1} have gone colder on us.", tostring(b.name)))
                end
            end
            return res
        end
    end
    -- traders passing through
    M.cvArriveHooks = M.cvArriveHooks or {}
    table.insert(M.cvArriveHooks, function(visit, b, h) pcall(M.elAdd, "trade", tr("ElogTraders", "Traders from {1} came by.", tostring(b and b.name or "somewhere"))) end)
    -- missing
    if fn(M, "msOpen") then
        local orig = M.msOpen
        M.msOpen = function(uid, ...)
            local res = orig(uid, ...)
            pcall(M.elAdd, "loss", tr("ElogMissing", "Nobody's seen {1} in a while.", M.qolName(uid)))
            return res
        end
    end
    -- why not: coming along (only when you asked: their own "mind if I tag along?" check stays silent)
    if fn(M, "partyOfferTick") then
        local orig = M.partyOfferTick
        M.partyOfferTick = function(...)
            M._qolPassive = true
            local ok, a, b = pcall(orig, ...)
            M._qolPassive = false
            if not ok then error(a, 0) end
            return a, b
        end
    end
    if fn(M, "recruitVerdict") then
        local orig = M.recruitVerdict
        M.recruitVerdict = function(listener, player, ...)
            local ok, why, need, v = orig(listener, player, ...)
            if not ok and not M._qolPassive and type(listener) == "table" and type(listener.record) == "table" and why then
                pcall(M.whyNot, listener.record.uid, tr("WhyCome", "come with you"), why)
            end
            return ok, why, need, v
        end
    end
    -- why not: a job
    if fn(M, "cpSetRole") then
        local orig = M.cpSetRole
        M.cpSetRole = function(uid, role, player, ...)
            local line, took = orig(uid, role, player, ...)
            if took == false then pcall(M.whyNot, uid, tr("WhyRole", "take that job"), M.qolRoleWhy[role] or "says they're not the one for it") end
            return line, took
        end
    end
    -- pre-1.0 MP: the right-click entry, the panels and the notice log are on the screen side (ALifeTalk_QoL_UI.lua)
    return true
end

-- the names you gave places: your own people use them when they talk (the AI's brief)
if type(M.requestExtras) == "table" and not M._qolExtras then
    M._qolExtras = true
    table.insert(M.requestExtras, function(req, player, listener, now)
        if M.settings.namedPlaces == false or type(listener) ~= "table" or type(listener.record) ~= "table" then return end
        local uid = tostring(listener.record.uid)
        if not (camp(uid) or member(uid)) then return end
        local names = M.plNames()
        if #names > 0 then
            local n = {}
            for i = 1, math.min(8, #names) do n[i] = names[i] end
            req.places = n
        end
        local o = M.plOrderOf(uid)
        local pl = o and M.plGet(o.place)
        if pl then req.placeOrder = (o.mode == "hold" and "holding " or "waiting to meet them at ") .. pl.name end
    end)
end

local broken = false
local function tick()
    if broken then return end
    local ok, err = pcall(M.plTick)
    if not ok then broken = true; print("[ALifeQoL] place orders failed, named-place orders off for this session: " .. tostring(err)) end
end
if not M._qolTick then
    M._qolTick = true
    if type(ALifeHealth) == "table" then ALifeHealth.tickAdd("ALifeTalk_QoL", tick) elseif type(ALifeTick) == "table" then ALifeTick.add(tick) end
    if Events and Events.EveryHours then
        local hb = false
        local function hourly() if hb then return end; local ok, err = pcall(M.elHourly); if not ok then hb = true; print("[ALifeQoL] event log failed, store notes off for this session: " .. tostring(err)) end end
        if type(ALifeHealth) == "table" then ALifeHealth.add(Events.EveryHours, "ALifeTalk_QoL", hourly) else Events.EveryHours.Add(hourly) end
    end
    if Events and Events.OnGameStart then Events.OnGameStart.Add(function() local ok, err = pcall(M.qolInstall); if not ok then print("[ALifeQoL] install failed, quality-of-life hooks off for this session: " .. tostring(err)) end end) end
end
-- pre-1.0 MP (P4): the windows' calls on an MP client run on the server as the sender (ALifeRemote, plain values)
function M.bulkOrder1(uid, id, arg, player)
    local n = M.bulkOrder({ tostring(uid) }, tostring(id), arg)
    if mpServer() and player ~= nil and type(ALifeOut) == "table" then
        ALifeOut.toast(player, n == 0 and tr("OrderNot", "Nobody took that order.") or tr("OrderTook", "{1} took the order.", M.qolName(uid)))
    end
    qolTouch()
    return n
end
function M.plRecallAs(uid) M.plRecall(uid); qolTouch(); return true end
require "ALifeNPCOverhaul/ALifeRemote"
if type(ALifeRemote) == "table" then
    local R = ALifeRemote
    R.expose("plAdd", 4, 5)
    R.expose("plRemove", 1, 2)
    R.expose("plOrder", 3, 4)
    R.expose("plRecall", 1, 2)
    R.expose("qoRun", 2, 3)
    R.expose("bulkOrder1", 3, 4)
    R.share(M.QOL_VIEW, function() local st = store(); return { elog = st.elog, places = st.places, plOrders = st.plOrders } end)
end
print("[ALifeQoL] loaded v0.7.0.1 (notices, event log, why not, named places, orders, widget, quick-order bar)")
