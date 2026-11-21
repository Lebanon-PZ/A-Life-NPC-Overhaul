-- A-Life NPC Overhaul 0.8.12 (Rock List 2): THE PARTY TAB, AS CARDS. One card per person with you (and your settlers
-- at home after them): their figure in the clothes they wear right now, name, role, how they are toward you, health,
-- hunger, thirst, mood, what they're doing, the order they're on, gear, what they're wearing, and the last few lines
-- of your journal about them. Words, never numbers (immersive off brings the numbers back).
-- Click a card to pick someone; the buttons below give the order. Cards page (Prev / Next) instead of scrolling, so
-- the 3D figures never draw outside the window.
-- Figure: live when they're loaded near you (the real character: real clothes); otherwise how A-Life remembers them
-- (People page's winDescOf: A-Life's appearance plan), with "as you last saw them".
-- Settings (ALifeCues.DEFAULTS): partyCards (off = the old list window), partyAvatars (6), partyJournal (3).
-- Performance: data every 2 s while the tab is open; figures re-bound every 5 s; one figure per card on the page.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("ui", "ALifeTalk_PartyCards") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
require "ALifeNPCOverhaul/ALifeCues"
local M = ALifeLLMTalk
local U = ALifeCues
if type(M) ~= "table" or type(U) ~= "table" then return end
local TAG = "[ALifePartyCards]"
ALifePartyCards = ALifePartyCards or {}
local K = ALifePartyCards
K.VERSION = ALifeSide.MOD_VERSION
U.registerSettings()

local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function now() return type(getTimestampMs) == "function" and getTimestampMs() or 0 end
local function playerOf() local p = nil; pcall(function() p = ALifeSide.you() end); return p end
local function num(k) return tonumber(U.setting(k)) or U.DEFAULTS[k] end
local tr = U.tr

----------------------------------------------------------------------------------------------------------------
-- data (no UI: testable)
----------------------------------------------------------------------------------------------------------------
local function shellFor(uid)
    local sh = nil
    pcall(function() sh = PA().Talk.shellFor(uid) end)
    return sh or U.shellOf(uid)
end
local function roleOf(uid)
    if fn(M, "cpRoleOf") and type(M.cpRoleLabel) == "table" then
        local ok, r = pcall(M.cpRoleOf, uid)
        if ok and r and r ~= "general" then return M.cpRoleLabel[r] end
    end
    local cc, D = PA().CompanionClient, PA().CompanionSheetData
    if type(cc) == "table" and type(cc.rows) == "table" and fn(D, "role") then
        for _, row in ipairs(cc.rows) do
            if type(row) == "table" and tostring(row.uid) == uid then
                local ok, role = pcall(D.role, row)
                if ok and type(role) == "table" and role.id ~= "general" then return role.label end
            end
        end
    end
    return nil
end
function K.journal(uid, n)
    local out = {}
    if not fn(M, "histRows") then return out end
    local ok, rows = pcall(M.histRows, uid)
    if not ok or type(rows) ~= "table" then return out end
    for i = #rows, math.max(1, #rows - (n - 1)), -1 do
        local r = rows[i]
        if type(r) == "table" and r.text then out[#out + 1] = { when = r.when, text = tostring(r.text) } end
    end
    return out
end
-- the cards: the Party rows (members, then settlers at home) + figure, role, wearing, journal
function K.cards(player, home)
    local get = M.partyRows or M.partyData
    if type(get) ~= "function" then return {} end
    local ok, rows = pcall(get, player)
    if not ok or type(rows) ~= "table" then return {} end
    local out = {}
    for _, d in ipairs(rows) do
        -- home: true = only settlers at your base (the "At home" tab), false = only people with you (Party), nil = all
        if type(d) == "table" and d.uid and (home == nil or (d.atBase == true) == home) then
            local uid = tostring(d.uid)
            local c = {}
            for k, v in pairs(d) do c[k] = v end
            c.uid = uid
            c.shell = shellFor(uid)
            c.live = c.shell ~= nil
            c.role = roleOf(uid)
            c.wearing = U.wornOf(c.shell, 8)
            c.journal = K.journal(uid, math.max(0, num("partyJournal")))
            out[#out + 1] = c
        end
    end
    return out
end
-- grid: 2 columns when there is room for them, card height from the font; returns cols, cardW, cardH, perPage
function K.layout(w, h, fh)
    fh = tonumber(fh) or 14
    local gap = 8
    local cols = w >= 760 and 2 or 1
    local cardW = math.floor((w - gap * (cols - 1)) / cols)
    local cardH = math.max(210, fh * 12 + 24)
    local rows = math.max(1, math.floor((h + gap) / (cardH + gap)))
    return cols, cardW, cardH, cols * rows, gap
end
-- one card's chips: { text, tone } (health, hurts, hunger, thirst, mood)
function K.chips(c, plain)
    local out = {}
    local w, t = U.hpWord(c.hp)
    if plain and tonumber(c.hp) then w = w .. " (" .. math.floor(tonumber(c.hp)) .. ")" end
    if not c.atBase then out[#out + 1] = { w, t } end
    for part in string.gmatch(tostring(c.hurt or ""), "[^,]+") do out[#out + 1] = { (string.gsub(part, "^%s+", "")), "red" } end
    local hw, ht = U.needWord("hunger", c.hunger)
    local tw, tt = U.needWord("thirst", c.thirst)
    if hw then out[#out + 1] = { hw, ht } end
    if tw then out[#out + 1] = { tw, tt } end
    if hw == nil and tw == nil and c.hunger ~= nil and not c.atBase then out[#out + 1] = { tr("Fed", "fed and watered"), "green" } end
    if type(c.mood) == "string" and c.mood ~= "" then out[#out + 1] = { c.mood, "dim" } end
    return out
end

----------------------------------------------------------------------------------------------------------------
-- orders (the old Party window's buttons, same calls)
----------------------------------------------------------------------------------------------------------------
local function say(text) if fn(M, "momToast") then pcall(M.momToast, text) end end
function K.command(win, cmd)
    local c = win and win:selected()
    if c == nil then say(tr("PickFirst", "Click someone's card first.")); return end
    local uid, player = c.uid, playerOf()
    if c.atBase and cmd ~= "talk" then
        if cmd == "follow" and fn(M, "baseAsk") then
            local ok, why = M.baseAsk(uid, player, "party window")
            if ok == nil and ALifeSide.mpClient() then say(tr("Asked", "Asked.")); return end -- pre-1.0 MP: the server answers out loud
            say(ok and (tr("Coming", "They're coming: ") .. tostring(why)) or (tr("Staying", "They'd rather stay: ") .. tostring(why)))
        else
            say(tr("AskFirst", "They live at your base. Ask them along first (Follow)."))
        end
        return
    end
    if not fn(M, "partyCommand") then return end
    if cmd == "stance" then
        local b = M.bucket and M.bucket("party")[uid] or (M.partyRowOf and M.partyRowOf(uid)) or {} -- pre-1.0 MP: the server's view
        local list = M.partyStances or { "aggressive", "defensive", "passive" }
        local nextS = list[1]
        for i, s in ipairs(list) do if s == b.stance then nextS = list[(i % #list) + 1] end end
        M.partyCommand(uid, nextS, player)
        say(tostring(c.name) .. ": " .. nextS)
    elseif cmd == "dismiss" then
        local T = M.Theme
        if T and fn(T, "confirm") then T.confirm(tr("Dismiss", "Part ways with {1}?", tostring(c.name)), function() M.partyCommand(uid, "dismiss", player) end)
        else M.partyCommand(uid, "dismiss", player) end
    else
        local ok = M.partyCommand(uid, cmd, player)
        if not ok then say(tostring(c.name) .. tr("Didnt", " didn't (or couldn't).")) end
        if cmd == "talk" then pcall(function() win:close() end) end
    end
    win.dataAt = 0
end

----------------------------------------------------------------------------------------------------------------
-- the page
----------------------------------------------------------------------------------------------------------------
function K.build(opts)
    opts = opts or {}
    local home = opts.home == true
    local kit = M.winKit
    local HP = ALifeTalkHubPage
    local T, S = M.Theme, M.UIStyle
    if type(kit) ~= "table" or HP == nil or T == nil or S == nil then return nil end
    local P
    if home then
        P = kit.page("ALifeTalkHomeCards", "At home", "home",
            tr("TipHome", "<SIZE:medium> At home <LINE> <SIZE:small> The people who live at your base, one card each: how they're doing and the last things you know about them. Click a card, then Follow to ask them along, or Talk. Everyone who is with you is under Party."))
    else
        P = kit.page("ALifeTalkPartyCards", "Party", "party",
            tr("Tip", "<SIZE:medium> Party <LINE> <SIZE:small> Everyone with you, one card each: how they look right now, how they're doing, the order they're on, their gear and the last things you know about them. Click a card, then an order below. Your settlers at home are under At home."))
    end
    local function tone(name) return ({ red = S.red, amber = S.amber, green = S.green, dim = S.dim })[name or ""] or S.text end
    local function font(self) return self.font or S.font end

    function P:createChildren()
        self.page = self.page or 1
        self.avatars = self.avatars or {}
        self.cards = self.cards or {}
        HP.createChildren(self)
        pcall(function() self.body:setVisible(false) end)
    end
    function P:selected()
        for _, c in ipairs(self.cards or {}) do if c.uid == self.cur then return c end end
        return nil
    end
    function P:actions()
        local acts = {}
        local list = { { "Follow", "follow" }, { "Wait", "hold" }, { "Guard here", "guard" }, { "Go to base", "base" }, { "Talk", "talk" },
                { "Stance", "stance" }, { "Part ways", "dismiss" } }
        if home then list = { { "Follow", "follow" }, { "Talk", "talk" } } end -- settlers at home: ask along, or talk
        for _, a in ipairs(list) do
            local cmd = a[2]
            -- Nov17: a settler at home is not in your party: Wait / Guard / Go to base / Stance / Part ways only
            -- answered "They live at your base" (or a refusal) there, so they show on a follower's card only
            local needsMember = cmd ~= "follow" and cmd ~= "talk"
            acts[#acts + 1] = { label = tr("Btn_" .. cmd, a[1]), fn = function(win) K.command(win, cmd) end, accent = cmd == "dismiss" and S.red or nil,
                show = needsMember and function() local c = self:selected(); return c == nil or not c.atBase end or nil }
        end
        acts[#acts + 1] = { label = "<", tip = tr("Prev", "Previous page"), show = function() return (self.pages or 1) > 1 end,
            fn = function(win) win.page = math.max(1, (win.page or 1) - 1); win:bindAvatars(true) end }
        acts[#acts + 1] = { label = ">", tip = tr("Next", "Next page"), show = function() return (self.pages or 1) > 1 end,
            fn = function(win) win.page = math.min(win.pages or 1, (win.page or 1) + 1); win:bindAvatars(true) end }
        return acts
    end
    function P:layoutMore(top, by)
        self.area = { x = 10, y = top + 4, w = self.width - 20, h = math.max(80, by - top - 12) }
        self:bindAvatars(false)
    end
    -- rebuild the buttons when the picked card switches between "with you" and "at your base"
    function P:syncButtons()
        local c = self:selected()
        local sig = c and (c.uid .. (c.atBase and ":base" or ":party")) or "none"
        if sig == self.btnSig then return end
        self.btnSig = sig
        pcall(function() self:buildButtons(); self:layout() end)
    end
    function P:refresh()
        local ok, cards = pcall(K.cards, playerOf(), home)
        self.cards = ok and cards or {}
        if self.cur == nil and self.cards[1] then self.cur = self.cards[1].uid end
        self:syncButtons()
        local a = self.area
        if a then
            local _, _, _, per = K.layout(a.w, a.h, T.fontH(font(self)))
            local pages = math.max(1, math.ceil(#self.cards / per))
            if pages ~= self.pages then self.pages = pages; self:buildButtons(); self:layout() end
            self.page = math.min(self.page or 1, pages)
        end
        self:bindAvatars(false)
        self.refreshedAt = now()
    end
    -- the card rectangles on this page
    function P:slots()
        local a = self.area
        if a == nil then return {} end
        local cols, cw, ch, per, gap = K.layout(a.w, a.h, T.fontH(font(self)))
        local out = {}
        local first = ((self.page or 1) - 1) * per
        for i = 1, per do
            local c = (self.cards or {})[first + i]
            if c == nil then break end
            local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
            out[#out + 1] = { c = c, x = a.x + col * (cw + gap), y = a.y + row * (ch + gap), w = cw, h = ch }
        end
        return out
    end
    local function avatarRect(s) local aw = math.max(80, math.min(130, math.floor(s.w * 0.3))); return s.x + 8, s.y + 8, aw, s.h - 16 end
    -- one figure per card: live character (real clothes) or A-Life's remembered look
    function P:bindAvatars(force)
        if self.avatarsOff then return end
        local slots = self:slots()
        local cap = math.max(0, num("partyAvatars"))
        for i = 1, math.max(#slots, #self.avatars) do
            local s = slots[i]
            local m = self.avatars[i]
            if s and i <= cap then
                if m == nil then
                    local okM, mdl = pcall(function()
                        local x, y, w, h = avatarRect(s)
                        local mm = ISUI3DModel:new(x + 1, y + 1, w - 2, h - 2)
                        mm:initialise()
                        self:addChild(mm)
                        mm:setIsometric(false)
                        mm:setDirection(IsoDirections.S)
                        mm:setDoRandomExtAnimations(false)
                        mm:setState("idle")
                        return mm
                    end)
                    if not okM then self.avatarsOff = true; print(TAG .. " no 3D figures: " .. tostring(mdl)); return end
                    m = mdl
                    self.avatars[i] = m
                end
                local x, y, w, h = avatarRect(s)
                pcall(function() m:setX(x + 1); m:setY(y + 1); m:setWidth(w - 2); m:setHeight(h - 2) end)
                if force or m.uid ~= s.c.uid or now() - (m.boundAt or 0) > 5000 then
                    m.uid, m.boundAt = s.c.uid, now()
                    local shown = false
                    if s.c.shell then shown = pcall(function() m:setCharacter(s.c.shell) end) end
                    if not shown then
                        pcall(function() m:setCharacter(nil) end)
                        local desc = fn(M, "winDescOf") and M.winDescOf(s.c.uid) or nil
                        if desc then shown = pcall(function() m:setSurvivorDesc(desc) end) end
                    end
                    m.shown = shown
                end
                s.c.figure = m.shown
                pcall(function() m:setVisible(m.shown == true) end)
            elseif m then
                pcall(function() m:setVisible(false) end)
                m.uid = nil
            end
        end
    end
    function P:update()
        ALifeLLMTalkWindow.update(self)
        if now() - (self.refreshedAt or 0) > 2000 then pcall(self.refresh, self) end
    end
    function P:onMouseDown(x, y)
        if x >= self.width - HP.grip and y >= self.height - HP.grip then return HP.onMouseDown(self, x, y) end
        for _, s in ipairs(self:slots()) do
            if x >= s.x and x < s.x + s.w and y >= s.y and y < s.y + s.h then self.cur = s.c.uid; self:syncButtons(); return true end
        end
        return HP.onMouseDown(self, x, y)
    end
    -- wrap words into at most n lines of width w
    local function wrap(text, w, f, n)
        local lines, line = {}, ""
        for word in string.gmatch(tostring(text or ""), "%S+") do
            local test = line == "" and word or (line .. " " .. word)
            if T.textW(test, f) > w and line ~= "" then lines[#lines + 1] = line; line = word else line = test end
        end
        if line ~= "" then lines[#lines + 1] = line end
        if #lines > n then lines[n] = T.fit(lines[n] .. " " .. table.concat(lines, " ", n + 1), w, f); for i = #lines, n + 1, -1 do lines[i] = nil end end
        return lines
    end
    function P:drawCard(s)
        local c, f = s.c, font(self)
        local fh = T.fontH(f)
        local sel = c.uid == self.cur
        local a = self.fade or 1
        T.box(self, s.x, s.y, s.w, s.h, sel and { a = 0.92, r = 0.16, g = 0.15, b = 0.13 } or S.panel, sel and S.border or S.borderDim, a)
        if c.atBase then self:drawRect(s.x + 1, s.y + 1, s.w - 2, s.h - 2, 0.25 * a, 0, 0, 0) end
        -- figure frame
        local ax, ay, aw, ah = avatarRect(s)
        self:drawRect(ax, ay, aw, ah, 0.7 * a, 0.045, 0.045, 0.05)
        self:drawRect(ax, ay + ah - math.floor(ah * 0.18), aw, math.floor(ah * 0.18), 0.35 * a, 0.2, 0.17, 0.12) -- floor glow
        T.box(self, ax - 1, ay - 1, aw + 2, ah + 2, nil, sel and S.border or S.borderDim, a)
        if not c.figure then
            local ini = string.upper(string.sub(tostring(c.name or "?"), 1, 1))
            self:drawTextCentre(ini, ax + aw / 2, ay + ah / 2 - T.fontH(S.fontBig) / 2, S.dim.r, S.dim.g, S.dim.b, 0.6 * a, S.fontBig)
        elseif not c.live then
            self:drawTextCentre(tr("LastSaw", "as you last saw them"), ax + aw / 2, ay + ah - fh - 4, S.dim.r, S.dim.g, S.dim.b, 0.8 * a, UIFont.Small)
        end
        -- text column
        local x = ax + aw + 12
        local w = s.x + s.w - x - 10
        local y = s.y + 8
        local tf = S.fontTitle
        local tag = c.atBase and tr("AtBase", "At your base") or (c.live and tr("WithYou", "With you") or tr("Away", "Out of sight"))
        local tagC = c.atBase and S.amber or (c.live and S.green or S.dim)
        local tagW = T.textW(tag, f) + 12
        self:drawText(T.fit(tostring(c.name or "?"), w - tagW - 8, tf), x, y, S.accent.r, S.accent.g, S.accent.b, a, tf)
        T.badge(self, s.x + s.w - 10 - tagW, y + 2, tag, tagC, a)
        y = y + T.fontH(tf) + 2
        -- role + how they are toward you
        local plain = M.settings.immersive == false
        local b = U.band(c.opinion)
        local feel = U.tr("Band_" .. b, U.BAND_WORDS[b] or "")
        if plain and tonumber(c.opinion) then feel = feel .. " (" .. math.floor(tonumber(c.opinion)) .. ")" end
        local fc = (b == "hate" or b == "wary") and S.amber or ((b == "like" or b == "trust") and S.green or S.dim)
        local rx = x
        if c.role then self:drawText(c.role, rx, y, S.text.r, S.text.g, S.text.b, a, f); rx = rx + T.textW(c.role, f) + 10 end
        self:drawText(T.fit(feel, x + w - rx, f), rx, y, fc.r, fc.g, fc.b, a, f)
        y = y + fh + 6
        -- chips
        local cx = x
        for _, chip in ipairs(K.chips(c, plain)) do
            local cw = T.textW(chip[1], S.font) + 12
            if cx + cw > x + w then cx = x; y = y + T.fontH(S.font) + 8 end
            T.badge(self, cx, y, chip[1], tone(chip[2]), a)
            cx = cx + cw + 5
        end
        y = y + T.fontH(S.font) + 10
        local function line(label, value, col)
            if value == nil or value == "" or y + fh > s.y + s.h - 6 then return end
            local lw = T.textW(label, f)
            self:drawText(label, x, y, S.dim.r, S.dim.g, S.dim.b, a, f)
            col = col or S.text
            self:drawText(T.fit(tostring(value), w - lw - 6, f), x + lw + 6, y, col.r, col.g, col.b, a, f)
            y = y + fh + 2
        end
        if c.atBase then
            local ask = c.ask or {}
            line(tr("Ask", "Ask along:"), ask.enabled and tr("AskYes", "click their card, then Follow") or tostring(ask.hint or ""))
        else
            line(tr("Order", "Order:"), tostring(c.orderText or c.order or "") .. ((c.stance and c.stance ~= "") and ("  -  " .. tostring(c.stance)) or ""))
            line(tr("Gear", "Gear:"), U.gearLine(c.gear))
        end
        if type(c.activity) == "string" then line(tr("Doing", "Doing:"), c.activity, S.dim) end
        if #(c.wearing or {}) > 0 and y + fh <= s.y + s.h - 6 then
            local lw = T.textW(tr("Wearing", "Wearing:"), f)
            self:drawText(tr("Wearing", "Wearing:"), x, y, S.dim.r, S.dim.g, S.dim.b, a, f)
            for i, l in ipairs(wrap(table.concat(c.wearing, ", "), w - lw - 6, f, 2)) do
                if y + fh > s.y + s.h - 6 then break end
                self:drawText(l, x + lw + 6, y, S.text.r, S.text.g, S.text.b, a, f)
                y = y + fh + 1
            end
            y = y + 1
        end
        -- journal
        if #(c.journal or {}) > 0 and y + fh * 2 <= s.y + s.h - 6 then
            y = y + 3
            self:drawRect(x, y, w, 1, 0.5 * a, S.borderDim.r, S.borderDim.g, S.borderDim.b)
            y = y + 4
            self:drawText(tr("Lately", "LATELY"), x, y, S.accent.r, S.accent.g, S.accent.b, 0.8 * a, UIFont.Small)
            y = y + T.fontH(UIFont.Small) + 1
            for _, j in ipairs(c.journal) do
                if y + fh > s.y + s.h - 6 then break end
                local when = j.when and (tostring(j.when) .. "  ") or ""
                local ww = T.textW(when, UIFont.Small)
                self:drawText(when, x, y, S.dim.r, S.dim.g, S.dim.b, 0.8 * a, UIFont.Small)
                self:drawText(T.fit(j.text, w - ww, UIFont.Small), x + ww, y, S.text.r, S.text.g, S.text.b, 0.9 * a, UIFont.Small)
                y = y + T.fontH(UIFont.Small) + 1
            end
        end
    end
    function P:render()
        HP.render(self)
        local slots = self:slots()
        for _, s in ipairs(slots) do pcall(self.drawCard, self, s) end
        local a, f = self.area, font(self)
        if a and #slots == 0 then
            self:drawTextCentre(home and tr("EmptyHome", "Nobody lives at your base yet.") or tr("Empty", "Nobody's travelling with you. Ask someone you trust: \"want to roll with me?\""), a.x + a.w / 2, a.y + a.h / 2 - 10, S.dim.r, S.dim.g, S.dim.b, self.fade or 1, f)
        end
        if (self.pages or 1) > 1 and a then
            local t = tostring(self.page or 1) .. " / " .. tostring(self.pages)
            self:drawText(t, self.width - 14 - T.textW(t, f), 6, S.dim.r, S.dim.g, S.dim.b, self.fade or 1, f)
        end
    end
    function P:onPageClose()
        for _, m in ipairs(self.avatars or {}) do pcall(function() m:setCharacter(nil) end) end
    end
    return P
end

function K.addTab()
    if K.tabAdded then return true end
    if U.setting("partyCards") == false or not fn(M, "hubAddTab") then return false end
    local P = K.build()
    if P == nil then return false end
    K.Page = P
    local kit = M.winKit
    M.hubAddTab({ id = "party", label = "Party", class = "ALifeTalkPartyCards", open = function() return kit.openPage(P, "partyWindow") end,
        ref = function() return M.partyWindow end, show = function() return M.settings.party ~= false end })
    -- Nov17: settlers at home get their own tab, after Party
    local H = K.build({ home = true })
    if H ~= nil then
        K.HomePage = H
        M.hubAddTab({ id = "home", label = "At home", class = "ALifeTalkHomeCards", open = function() return kit.openPage(H, "homeWindow") end,
            ref = function() return M.homeWindow end, show = function() return M.settings.party ~= false end }, "journal")
    end
    -- the radial / right-click "Party..." opens the cards too
    K.oldOpen = K.oldOpen or M.openParty
    M.openParty = function()
        if U.setting("partyCards") == false and K.oldOpen then return K.oldOpen() end
        if fn(M, "hubOpen") then return M.hubOpen("party") end
        return kit.openPage(P, "partyWindow")
    end
    if type(M.settingRows) == "table" then
        local have = {}
        for _, r in ipairs(M.settingRows) do have[r[1]] = true end
        for _, r in ipairs({ { "partyCards", "Party tab as cards: their figure in their clothes, how they're doing, a short journal (off: the old list; restart)" },
            { "partyAvatars", "Party tab: how many 3D figures at once (0 = none)", { 0, 2, 4, 6, 10 } },
            { "partyJournal", "Party tab: journal lines on each card", { 0, 2, 3, 5 } } }) do
            if not have[r[1]] then M.settingRows[#M.settingRows + 1] = r end
        end
    end
    if type(M.settingCatOf) == "table" then for _, k in ipairs({ "partyCards", "partyAvatars", "partyJournal" }) do M.settingCatOf[k] = M.settingCatOf[k] or "Party and orders" end end
    K.tabAdded = true
    return true
end
function K.install()
    pcall(K.addTab)
    print(TAG .. " ready v" .. K.VERSION .. ": Party tab " .. (K.tabAdded and "cards" or "old list") .. ", " .. tostring(num("partyAvatars")) .. " figures, "
        .. tostring(num("partyJournal")) .. " journal lines")
end
if type(Events) == "table" and Events.OnGameStart ~= nil then Events.OnGameStart.Add(function() pcall(K.install) end) end
return K
