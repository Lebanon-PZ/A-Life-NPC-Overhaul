-- A-Life Talk 0.5.1: PARTY WINDOW: dark GECK style list of members with health, mood, opinion, activity, weapon, stance and command buttons
-- (behind a settings toggle; every Java / A-Life call guarded; yields to danger: lines only when idle and not fighting)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "PartyUI"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("PartyUI") end end -- 0.5.1.6 perf label
local M = ALifeLLMTalk
if type(M) ~= "table" then return end
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function fn(t, name) return type(t) == "table" and type(t[name]) == "function" end
local function log(msg) M.log(msg) end
local function nowMs() return M.nowMs() end
local function patch() return M.patch and M.patch() or nil end
local function pos(o) if o == nil then return nil end; local x, y, z = nil, nil, nil; pcall(function() x, y, z = o:getX(), o:getY(), o:getZ() end); return x, y, z end
local function hash(s) local h = 5381; s = tostring(s); for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end; return h end
local function pick(list, seed) return list[(hash(seed) % #list) + 1] end
local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return h end
local function bucket(name) return M.bucket(name) end
local function rec(uid) local pa = PA(); return pa and fn(pa.ActorRegistry, "read") and pa.ActorRegistry.read(tostring(uid)) or nil end
local function nameOf(r) local pa = PA(); return (r and fn(pa.Names, "of") and pa.Names.of(r)) or "someone" end
local function firstOf(r)
    local m = type(r) == "table" and type(r.memory) == "table" and r.memory or {}
    if type(m.personFirst) == "string" and m.personFirst ~= "" then return m.personFirst end
    return string.match(nameOf(r), "^(%S+)") or nameOf(r)
end
local function setting(key, default)
    if M.settings[key] == nil then M.settings[key] = default end
    if type(M.fileKeys) == "table" then
        local have = false
        for _, x in ipairs(M.fileKeys) do if x == key then have = true end end
        if not have then M.fileKeys[#M.fileKeys + 1] = key end
    end
end
local function sayStock(p)
    local me = (M.refresh and M.refresh(p)) or p.listener
    local text = type(p.react) == "table" and p.react.fallback or nil
    if me == nil or type(text) ~= "string" or text == "" then return end
    if M.say then M.say(me.shell, p.player, text, { record = me.record }) end
    if M.voiceOnly then pcall(M.voiceOnly, me, p.player, text) end
end
-- react mode: the AI line, or (bridge failed / too slow) the canned line from react.fallback
local function regMode(mode) if type(M.eventModes) == "table" and M.reactRequest then M.eventModes[mode] = { request = M.reactRequest, finish = M.reactFinish, fallback = sayStock } end end
-- one line: the AI (react mode) with a canned fallback; voiced through the bridge either way when voice is on
M.spokeAt = M.spokeAt or {}
local function speak(l, player, mode, what, fallback, opts)
    opts = opts or {}
    local now = nowMs()
    local key = mode .. ":" .. tostring(l.record.uid)
    if now - (M.spokeAt[key] or -1e12) < (opts.keyMs or 120000) then return false end
    if now - (M.spokeAt[mode] or -1e12) < (opts.modeMs or 20000) then return false end
    if not opts.urgent and now - (M.lastPlayerLineAt or -1e12) < 4000 then return false end -- the player is talking
    M.spokeAt[key], M.spokeAt[mode] = now, now
    local ok = M.react and player and M.react(mode, l, player, { what = what, style = opts.style or "short, in character, out loud", maxWords = opts.maxWords or 14,
        fallback = fallback }, { key = key, keyCooldownMs = 0, modeCooldownMs = 0, urgent = opts.urgent, face = opts.face })
    if not ok and fallback then
        if M.say then M.say(l.shell, player, fallback, { record = l.record }) end
        if M.voiceOnly then pcall(M.voiceOnly, l, player, fallback) end
    end
    return true
end
local function nearPlayer(tiles)
    local player = ALifeSide.you()
    if player == nil then return {}, nil end
    local x, y, z = pos(player)
    return (M.nearbyNpcs and M.nearbyNpcs(x, y, z, tiles) or {}), player
end
local function idleOk(l, now)
    local pa = PA()
    if fn(pa.Talk, "busy") and pa.Talk.busy(l.record, now) then return false end
    if M.inCombat and M.inCombat(l.shell, l.record) then return false end
    return true
end
local function everyMs(ms, f)
    if type(Events) ~= "table" or not Events.OnTick then return end
    local last = -1e12
    ALifeHealth.tickAdd("ALifeLLMTalk_PartyUI", function()
        local now = nowMs()
        if now - last < ms then return end
        last = now
        local ok, e = pcall(f, now)
        if not ok then log("tick error: " .. tostring(e)) end
    end)
end
----------------------------------------------------------------------------------------------------------------
-- 0.8.12 (Rock List 2): PARTY PANEL: hunger, thirst, order, gear on each row (words, not numbers).
-- Needs: A-Life's companion roster (CompanionClient.rows, 0-100, works in multiplayer), else in single player A-Life's
-- Companions.snapshot, else this mod's own life model (Psyche lifeOf, 0-1). Order: A-Life's order label, else the
-- last order you gave (M.lastOrder). Gear: ALifeCues.gearOf (A-Life Weapons.current / MagazineState.reserve / worn bag;
-- multiplayer falls back to the hand slot and A-Life's sheet extras, unverified).
----------------------------------------------------------------------------------------------------------------
require "ALifeNPCOverhaul/ALifeCues"
local function alifeRow(uid)
    local cc = PA().CompanionClient
    if type(cc) == "table" and type(cc.rows) == "table" then
        for _, row in ipairs(cc.rows) do if type(row) == "table" and tostring(row.uid) == uid then return row end end
    end
    local C = PA().Companions
    if fn(C, "snapshot") and not (type(isClient) == "function" and isClient()) then
        local ok, row = pcall(C.snapshot, uid)
        if ok and type(row) == "table" then return row end
    end
    return nil
end
local function orderWord(id)
    if id == nil then return nil end
    local cc = PA().CompanionClient
    if fn(cc, "label") then local ok, l = pcall(cc.label, id); if ok and type(l) == "string" and l ~= id then return l end end
    local q = type(M.qoById) == "table" and M.qoById[id] or nil
    if q and q.label then return q.label end
    local plain = { follow = "Follow me", hold = "Wait here", guard = "Guard here", base = "Go back to the base", talk = "Talk" }
    return plain[id] or tostring(id)
end
M.partyOrderWord = orderWord
function M.partyExtras(row, sh, player)
    if type(row) ~= "table" then return end
    local uid = tostring(row.uid)
    local ar = alifeRow(uid)
    if ar and type(ar.needs) == "table" then
        row.hunger, row.thirst = tonumber(ar.needs.hunger), tonumber(ar.needs.thirst)
    elseif fn(M, "lifeOf") then
        local ok, life = pcall(M.lifeOf, uid)
        if ok and type(life) == "table" then
            row.hunger = tonumber(life.hunger) and life.hunger * 100 or nil
            row.thirst = tonumber(life.thirst) and life.thirst * 100 or nil
        end
    end
    local lo = M.lastOrder and M.lastOrder[uid] or nil
    if ar and type(ar.order) == "string" then row.orderText = orderWord(ar.order)
    elseif lo and lo.kind then row.orderText = orderWord(lo.kind) .. (lo.obeyed == false and " (didn't)" or "")
    else row.orderText = orderWord(row.order) end
    local U = ALifeCues
    if type(U) == "table" and fn(U, "gearOf") then
        local okG, g = pcall(U.gearOf, sh)
        g = okG and type(g) == "table" and g or {}
        local sheet = PA().CompanionSheet
        local ex = type(sheet) == "table" and type(sheet.extras) == "table" and sheet.extras[uid] or nil
        if g.weapon == nil and type(ex) == "table" and type(ex.weapon) == "string" then
            g.weapon = ex.weapon
            if tonumber(ex.ammoLoaded) then g.gun = true; g.ammo = tonumber(ex.ammoLoaded) + (tonumber(ex.ammoReserve) or 0) end
        end
        if g.bag == nil and type(ex) == "table" and type(ex.bag) == "string" then g.bag = ex.bag end
        row.gear = g
        if g.weapon then row.weapon = g.weapon end
    end
end
require "ALifeLLMTalk/ALifeLLMTalk_Theme"
local T = M.Theme
if T == nil or ALifeLLMTalkWindow == nil then return M end
local S = M.UIStyle
ALifeTalkPartyWindow = ALifeLLMTalkWindow:derive("ALifeTalkPartyWindow")
local PW = ALifeTalkPartyWindow
PW.rowH = 78 -- 0.8.12: four lines (name / health + needs / order / gear)
function PW:new()
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    local w, h = 680, 500 -- 0.8.12: taller rows (needs, order, gear)
    w, h = tonumber(M.uiPref("party.w", w)) or w, tonumber(M.uiPref("party.h", h)) or h
    local o = ALifeLLMTalkWindow.new(self, math.floor((sw - w) / 2), math.floor((sh - h) / 2), w, h, "Party")
    o.rsKey, o.minW, o.minH = "party", 560, 360
    return o
end
function PW:createChildren()
    ALifeLLMTalkWindow.createChildren(self)
    local top = self:contentTop()
    local win = self
    self.list = T.list(self, S.pad, top, self.width - S.pad * 2, self.height - top - 80, PW.rowH, function(list, y, item, alt) return win:drawRow(list, y, item, alt) end)
    local bx, by = S.pad, self.height - 66
    self.cmdBtns = {}
    local cmds = { { "Follow", "follow" }, { "Wait / Hold", "hold" }, { "Guard area", "guard" }, { "Go to base", "base" }, { "Talk", "talk" }, { "Stance", "stance" }, { "Dismiss", "dismiss" } }
    for _, c in ipairs(cmds) do
        local w = T.textW(c[1]) + 20
        self.cmdBtns[#self.cmdBtns + 1] = T.button(self, bx, by, w, 24, c[1], self, function() self:command(c[2]) end, c[2] == "dismiss" and S.red or nil)
        bx = bx + w + 6
    end
    self.status = ""
    self:refresh()
end
function PW:onResized()
    local top = self:contentTop()
    if self.list then
        self.list:setWidth(self.width - S.pad * 2); self.list:setHeight(self.height - top - 80)
        if self.list.vscroll then self.list.vscroll:setHeight(self.list:getHeight()) end
    end
    for _, b in ipairs(self.cmdBtns or {}) do b:setY(self.height - 66) end
end
function PW:selectedUid()
    local i = self.list and self.list.selected or 0
    local it = self.list and self.list.items and self.list.items[i] or nil
    return it and it.item and it.item.uid or nil
end
function PW:command(cmd)
    local uid = self:selectedUid()
    if uid == nil then self.status = "Select someone first."; return end
    local player = ALifeSide.you()
    local it = self.list.items[self.list.selected or 0]
    if it and it.item and it.item.atBase then -- 0.5.1.8: a settler at home: Follow = ask them along; the rest doesn't apply
        if cmd == "follow" and M.baseAsk then
            local ok, why = M.baseAsk(uid, player, "party window")
            self.status = ok and ("They're coming: " .. tostring(why)) or ("They'd rather stay: " .. tostring(why))
            if ok == nil and type(ALifeSide) == "table" and ALifeSide.mpClient() then self.status = "Asked." end -- pre-1.0 MP: the server answers
        else
            self.status = "They live at your base - ask them along first (Follow)."
        end
        self:refresh()
        return
    end
    if cmd == "stance" then
        local b = M.bucket("party")[uid] or (M.partyRowOf and M.partyRowOf(uid)) or {} -- pre-1.0 MP: the server's view
        local nextS = "defensive"
        for i, s in ipairs(M.partyStances) do if s == b.stance then nextS = M.partyStances[(i % #M.partyStances) + 1] end end
        M.partyCommand(uid, nextS, player)
        self.status = "Stance: " .. nextS
    elseif cmd == "dismiss" then
        T.confirm("Dismiss them from the party?", function() M.partyCommand(uid, "dismiss", player); self:refresh() end)
        return
    else
        local ok = M.partyCommand(uid, cmd, player)
        self.status = ok and ("Order sent: " .. cmd) or ("They didn't (or couldn't): " .. cmd)
        if cmd == "talk" then self:close(); return end
    end
    self:refresh()
end
function PW:refresh()
    if self.list == nil then return end
    local sel = self.list.selected
    self.list:clear()
    local data = (M.partyRows or M.partyData)(ALifeSide.you()) -- 0.5.1.8: + settlers at the base
    local n = 0
    for _, d in ipairs(data) do self.list:addItem(d.name, d); if not d.atBase then n = n + 1 end end
    if sel and sel <= #data then self.list.selected = sel end
    self.count = n
end
-- 0.8.12 (Rock List 2): words, no numbers (immersive; the old HP / opinion numbers come back with immersive off)
local function tone(name) return ({ red = S.red, amber = S.amber, green = S.green, dim = S.dim })[name or ""] or S.text end
function PW:drawRow(list, y, item, alt)
    local d = item.item
    T.rowBack(list, y, item, alt)
    local a = self.fade or 1
    local c = d.here and S.text or S.dim
    local U = ALifeCues
    local plain = M.settings.immersive == false or type(U) ~= "table"
    local lh = math.floor((list.itemheight - 8) / 4)
    list:drawText(tostring(d.name), 10, y + 4, c.r, c.g, c.b, a, S.fontTitle)
    if d.where then -- 0.5.1.8: "At base" / "Travelling with you (lives at your base)"
        local wc = d.atBase and S.amber or S.blue
        list:drawText(tostring(d.where), 10 + T.textW(tostring(d.name)) + 40, y + 6, wc.r, wc.g, wc.b, a, S.font)
    end
    local rx = math.floor(list:getWidth() * 0.55)
    -- how they are toward you: a word (or the old bar + number)
    if plain then
        T.relBar(list, rx, y + 8, 160, 8, d.opinion, a)
        list:drawText(tostring(math.floor(d.opinion)), rx + 166, y + 4, S.dim.r, S.dim.g, S.dim.b, a, S.font)
    else
        local b = U.band(d.opinion)
        local bc = (b == "hate" or b == "wary") and S.amber or ((b == "like" or b == "trust") and S.green or S.dim)
        list:drawText(U.tr("Band_" .. b, U.BAND_WORDS[b] or ""), rx, y + 4, bc.r, bc.g, bc.b, a, S.font)
    end
    if d.atBase then
        local ask = d.ask or {}
        list:drawText(ask.enabled and "Select + Follow to ask them along" or tostring(ask.hint or ""), 10, y + 4 + lh, S.dim.r, S.dim.g, S.dim.b, a, S.font)
        if d.activity then list:drawText(tostring(d.activity), 10, y + 4 + lh * 2, S.dim.r, S.dim.g, S.dim.b, a, S.font) end
        return y + list.itemheight
    end
    -- line 2: health, hunger, thirst, mood
    local x = 10
    local function put(text, col)
        if text == nil or text == "" then return end
        if x > 10 then list:drawText(",", x - 2, y + 4 + lh, S.dim.r, S.dim.g, S.dim.b, a, S.font); x = x + 6 end
        list:drawText(text, x, y + 4 + lh, col.r, col.g, col.b, a, S.font)
        x = x + T.textW(text) + 4
    end
    if plain then
        local hpC = d.hp >= 70 and S.green or (d.hp >= 35 and S.amber or S.red)
        put("HP " .. math.floor(d.hp), hpC)
    else
        local w, t = U.hpWord(d.hp); put(w, tone(t))
    end
    if d.hurt ~= "" then put(d.hurt, S.red) end
    local hw, ht, tw, tt = nil, nil, nil, nil
    if type(U) == "table" then hw, ht = U.needWord("hunger", d.hunger); tw, tt = U.needWord("thirst", d.thirst) end
    put(hw, tone(ht)); put(tw, tone(tt))
    if hw == nil and tw == nil and d.hunger ~= nil then put("fed and watered", S.dim) end
    if d.mood and d.mood ~= "" then put(tostring(d.mood), S.dim) end
    -- line 3: the order they're on, the stance
    list:drawText("Order: " .. tostring(d.orderText or d.order) .. "   Stance: " .. tostring(d.stance), 10, y + 4 + lh * 2, S.dim.r, S.dim.g, S.dim.b, a, S.font)
    -- line 4: gear; activity on the right
    local gear = type(U) == "table" and U.gearLine(d.gear) or tostring(d.weapon)
    list:drawText("Gear: " .. gear, 10, y + 4 + lh * 3, S.text.r, S.text.g, S.text.b, a, S.font)
    if d.activity then list:drawText(tostring(d.activity), rx, y + 4 + lh, S.dim.r, S.dim.g, S.dim.b, a, S.font) end
    return y + list.itemheight
end
function PW:prerender()
    ALifeLLMTalkWindow.prerender(self)
    local cap = (M.partyCapNow and M.partyCapNow(ALifeSide.you()) or tonumber(M.settings.partyCap) or 6)
    self:drawText((self.count or 0) .. " / " .. cap, self.width - 80, 6, S.dim.r, S.dim.g, S.dim.b, self.fade or 1, S.font)
    self:drawText(tostring(self.status or ""), S.pad, self.height - 34, S.dim.r, S.dim.g, S.dim.b, self.fade or 1, S.font)
    if (self.count or 0) == 0 and (self.list == nil or #(self.list.items or {}) == 0) then
        self:drawTextCentre("Nobody's travelling with you. Ask someone you trust: \"want to roll with me?\"", self.width / 2, self.height / 2 - 20, S.dim.r, S.dim.g, S.dim.b, self.fade or 1, S.font)
    end
end
function PW:update()
    ALifeLLMTalkWindow.update(self)
    local now = T.now()
    if now - (self.refreshedAt or 0) > 1500 then self.refreshedAt = now; pcall(function() self:refresh() end) end
end
function M.openParty()
    if M.partyWindow then pcall(function() M.partyWindow:close() end) end
    M.partyWindow = T.open(PW:new())
    return M.partyWindow
end
if type(Events) == "table" and Events.OnFillWorldObjectContextMenu then
    ALifeRadial.addFiller("party", "windows", function(playerNum, context, worldobjects, test)   -- 0.5.11: radial registry
        if test == true or not M.settings.enabled or M.settings.party == false or type(context) ~= "table" or type(context.addOption) ~= "function" then return end
        if M.settings.immersive ~= true then pcall(function() T.menuOption(context, "A-Life: Party...", nil, function() pcall(M.openParty) end, "follow") end) end
    end)
end
return M
