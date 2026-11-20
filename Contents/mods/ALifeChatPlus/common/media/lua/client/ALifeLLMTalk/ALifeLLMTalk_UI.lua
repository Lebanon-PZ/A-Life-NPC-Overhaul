-- A-Life Talk 0.4.0: relationship windows (per-NPC panel with Overview / Memories / Ties / Interactions tabs, master
-- list with sorting + filtering), radio status bar and settings window - all on the shared dark theme
-- (ALifeLLMTalk_Theme.lua: ALifeLLMTalkWindow, UIStyle). Read-only views of A-Life data plus our own layers.
require "ALifeLLMTalk/ALifeLLMTalk_Main"
require "ALifeLLMTalk/ALifeLLMTalk_Theme"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "UI"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("UI") end end -- 0.5.1.6 perf label
require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISScrollingListBox"

local M = ALifeLLMTalk
if type(M) ~= "table" then return end

local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, name) return type(t) == "table" and type(t[name]) == "function" end

M.UIStyle = M.UIStyle or {}
local S0 = M.UIStyle
for k, v in pairs({
    -- headline buckets (label, max value, colour)
    bands = {
        { "Hostile", -41, { r = 0.85, g = 0.2, b = 0.18 } },
        { "Distrusts you", -16, { r = 0.9, g = 0.5, b = 0.2 } },
        { "Neutral", 15, { r = 0.75, g = 0.72, b = 0.6 } },
        { "Likes you", 40, { r = 0.55, g = 0.8, b = 0.35 } },
        { "Trusts you", 101, { r = 0.3, g = 0.8, b = 0.55 } },
    },
    kinds = { promise = "Promise", gift = "Gift", trade = "Trade", drink = "Drink", event = "Saw", death = "Death", insult = "Insult",
        threat = "Threat", kindness = "Kindness" },
    kindColor = { promise = { r = 0.95, g = 0.7, b = 0.25 }, death = { r = 0.9, g = 0.35, b = 0.3 }, threat = { r = 0.9, g = 0.35, b = 0.3 },
        insult = { r = 0.9, g = 0.55, b = 0.3 }, gift = { r = 0.6, g = 0.85, b = 0.45 }, kindness = { r = 0.6, g = 0.85, b = 0.45 },
        drink = { r = 0.85, g = 0.7, b = 0.35 }, trade = { r = 0.7, g = 0.75, b = 0.85 }, event = { r = 0.75, g = 0.72, b = 0.6 } },
    silhouette = { a = 0.9, r = 0.22, g = 0.22, b = 0.24 },
    portraitTexture = nil, -- optional texture path for a background frame
    radio = { r = 0.55, g = 0.9, b = 0.55 },
}) do S0[k] = v end
local S = M.UIStyle

function M.bandOf(v)
    v = tonumber(v) or 0 -- 0.4.2: never compare a non-number (was the "__le not defined" crash)
    for _, b in ipairs(S.bands) do if v <= b[2] then return b[1], b[3] end end
    local last = S.bands[#S.bands]
    return last[1], last[3]
end

----------------------------------------------------------------------------------------------------------------
-- Data for the panel (testable without UI)
----------------------------------------------------------------------------------------------------------------
function M.relationshipData(uid, player)
    local pa = PA()
    local rec = fn(pa.ActorRegistry, "read") and pa.ActorRegistry.read(uid) or nil
    if rec == nil and M.ghostRecord then rec = M.ghostRecord(uid) end -- 0.5.1.3: A-Life dropped them; our saved copy
    if rec == nil then return nil end
    local v, label, why = M.opinionView(rec, player)
    if rec.ghost then local e = M.bucket("book")[tostring(uid)]; if type(e) == "table" and e.value then v, label = tonumber(e.value) or v, e.label or label end end
    local band = M.bandOf(v)
    local name = (fn(pa.Names, "of") and pa.Names.of(rec)) or "Someone"
    if M.shownName and player ~= nil and M.settings.nameDiscovery ~= false and not rec.ghost then name = M.shownName(uid, player) end -- 0.5.1: as the game shows it
    if rec.ghost then local e = M.bucket("book")[tostring(uid)]; name = type(e) == "table" and e.name or name end
    local role = nil
    if fn(pa.DialogueRoles, "describe") then
        local okR, who = pcall(pa.DialogueRoles.describe, rec, 0)
        if okR and type(who) == "table" then role = who.label end
    end
    local rows = {}
    local list = M.keyMemOf and M.keyMemOf(uid) or {}
    for i = #list, 1, -1 do
        local e = list[i]
        rows[#rows + 1] = { kind = e.k, text = e.t, when = M.whenText and M.whenText(e) or ("Day " .. tostring(e.d) .. ", " .. tostring(e.tm)) } -- 0.5.2.5
    end
    local drunk, drunkLabel = 0, nil
    if M.drunkOf then drunk, drunkLabel = M.drunkOf(uid) end
    local radioOk, radioWhy = false, "Radio unavailable"
    if M.radioCheck then radioOk, radioWhy = M.radioCheck(player, uid) end
    -- v3.2: their ties to other people (our pair layer; only people you've met or heard of are named)
    local ties = {}
    if M.tiesOf then
        local okT, list2 = pcall(M.tiesOf, uid, player, 6)
        if okT and type(list2) == "table" then ties = list2 end
    end
    local youTie = nil
    if M.playerTie then
        local okY, word = pcall(M.playerTie, rec, player)
        if okY then youTie = word end
    end
    -- 0.4.0: personality, learned backstory, interaction log, mood, last talked + trend, nemesis tier
    local persona, story, inter = nil, {}, {}
    if M.personaOf then
        pcall(function()
            local row = M.personaOf(uid, (not rec.ghost) and rec or nil)
            local p = row and M.personaParts(row)
            if p then
                persona = { label = p.entry.label, traits = p.core.traits, speech = p.speech[1], speechHint = p.speech[2],
                    quirk = p.quirk, values = p.core.values, dislikes = p.core.dislikes, phrase = p.phrase }
            end
            story = M.learnedStory(uid)
        end)
    end
    -- 0.5.1.5: far away / no persona row -> the page saved while they were near (Profile.lua)
    local prof = (M.settings.farProfiles ~= false and M.profileOf) and M.profileOf(uid) or nil
    if persona == nil and prof and type(prof.persona) == "table" and prof.persona.label then persona = prof.persona end
    if role == nil and prof and prof.role then role = prof.role end
    if M.interactionsOf then inter = M.interactionsOf(uid) end
    local last, trend = nil, 0
    for i = #inter, 1, -1 do
        local r = inter[i]
        if last == nil and r.k == "talk" then last = M.whenText and M.whenText(r) or r.t end -- 0.5.2.5: same format as the timeline
        if i > #inter - 5 and r.a and r.b then trend = trend + (r.b - r.a) end
    end
    local factionName = nil
    if fn(pa.Catalog, "faction") then
        pcall(function()
            local f = pa.Catalog.faction(rec.factionId)
            if type(f) == "table" and type(f.general) == "table" then factionName = f.general.name end
        end)
    end
    if factionName == nil and prof and prof.fac then factionName = prof.fac end
    local nem = M.nemesisOf and M.nemesisOf(uid) or nil
    -- 0.5.2.10 [pt270u]: the shared past with their partner + "With Josh; grieving Jorge" + the bite
    local together, partnerLine, bite = nil, nil, nil
    if M.togetherView then pcall(function() together = M.togetherView(uid) end) end
    if M.partnerWord then pcall(function() partnerLine = M.partnerWord(uid) end) end
    if M.biteInfo and not rec.ghost then pcall(function() bite = M.biteInfo(uid) end) end
    -- 0.4.1: romance + promises (Overview) and the player's own row in Ties
    local romance, promises = nil, {}
    pcall(function()
        if M.romanceOf then
            local ro = M.romanceOf(uid)
            if (ro.stage or 0) >= 1 then
                romance = { stage = ro.stage, word = ({ "Fond of you", "Sweet on you", "Your partner" })[ro.stage],
                    since = ro.since }
            elseif ro.brokenH then
                -- 0.5.2.10 [pt270u]: their feelings for YOU broke (you insulted / attacked them); with a living partner
                -- it read as if their love life was over. Now it says it's about you, and only while it's fresh.
                if M.settings.sharedPast == false then romance = { stage = 0, word = "Heartbroken" }
                else
                    local hNow = 0
                    pcall(function() hNow = getGameTime():getWorldAgeHours() end)
                    if hNow - (tonumber(ro.brokenH) or 0) < 72 then romance = { stage = 0, word = "Hurt by you (feelings for you gone)" } end
                end
            end
        end
        if M.promisesOf then
            local now = getGameTime():getWorldAgeHours()
            local list = M.promisesOf(uid)
            for i = #list, math.max(1, #list - 4), -1 do
                local p = list[i]
                if p.state ~= "void" then
                    local due = (p.state == "open" and p.dueH) and (math.max(0, math.floor(p.dueH - now + 0.5)) .. " h left") or nil
                    promises[#promises + 1] = { text = M.promiseLabel(p), state = p.state, due = due }
                end
            end
        end
        if romance and romance.stage and romance.stage >= 1 then
            table.insert(ties, 1, { uid = "player", name = "You", type = romance.stage >= 3 and "partner" or "crush",
                word = romance.stage >= 3 and "partner" or (romance.stage == 2 and "sweet on you" or "fond of you"),
                score = v, why = romance.since and ("since day " .. tostring(romance.since)) or nil })
        end
    end)
    return { uid = tostring(uid), name = tostring(name), role = role, value = v, label = label, band = band, why = why,
        rows = rows, drunk = drunkLabel, dead = rec.lifecycle == "dead", faction = factionName or rec.factionId,
        radioOk = radioOk, radioWhy = radioWhy, ties = ties, youTie = youTie, persona = persona, story = story,
        interactions = inter, lastTalked = last, trend = trend, mood = M.moodWord and M.moodWord(v) or band,
        nemesis = nem, romance = romance, promises = promises, together = together, partnerLine = partnerLine, bite = bite,
        seen = (rec.ghost and M.bookAwayText and { away = true, text = M.bookAwayText(uid) }) or (M.lastSeenOf and M.lastSeenOf(uid, rec)) or nil,
        ghost = rec.ghost == true,
        love = (M.loveLine and M.settings.npcLove ~= false) and M.loveLine(uid) or nil }
end

-- v3.2: "Close with: Troy (brother), Janet (best friend)  |  Nemesis: Vic"
function M.closeWithLine(uid, player)
    if not M.tiesOf then return nil end
    local okT, ties = pcall(M.tiesOf, uid, player, 8)
    if not okT or type(ties) ~= "table" then return nil end
    local close, bad = {}, {}
    for _, t in ipairs(ties) do
        local label = t.name .. " (" .. tostring(t.word) .. ((t.dead and not t.late) and ", dead" or "") .. ")" -- 0.5.2.6: "(late partner)"
        if t.type == "nemesis" or t.type == "enemy" then
            if #bad < 1 then bad[#bad + 1] = label end
        elseif t.score >= 30 or t.type == "partner" or t.type == "sibling" or t.type == "parent" or t.type == "child" then
            if #close < 2 then close[#close + 1] = label end
        end
    end
    local out = ""
    if #close > 0 then out = "Close with: " .. table.concat(close, ", ") end
    if #bad > 0 then out = out .. (out ~= "" and "  |  " or "") .. "Against: " .. table.concat(bad, ", ") end
    return out ~= "" and out or nil
end

if ISPanel == nil or ISButton == nil or ISScrollingListBox == nil or ALifeLLMTalkWindow == nil then return M end
local T = M.Theme
local Base = ALifeLLMTalkWindow

local function wrapText(text, maxW, font)
    local out, line = {}, ""
    for word in string.gmatch(tostring(text or ""), "%S+") do
        local test = line == "" and word or (line .. " " .. word)
        if T.textW(test, font) > maxW and line ~= "" then out[#out + 1] = line; line = word else line = test end
    end
    if line ~= "" then out[#out + 1] = line end
    return out
end
M.wrapText = wrapText

----------------------------------------------------------------------------------------------------------------
-- Per-NPC window: Overview / Memories / Ties / Interactions
----------------------------------------------------------------------------------------------------------------
ALifeTalkRelationWindow = Base:derive("ALifeTalkRelationWindow")
local W = ALifeTalkRelationWindow
W.TABS = { "Personality", "Overview", "Memories", "Close with", "Interactions" } -- 0.5.0: Personality page, Ties -> Close with
W.TAB = { personality = 1, overview = 2, memories = 3, close = 4, interactions = 5 }
W.SMALL_W, W.SMALL_H, W.PAGE_W, W.PAGE_H = 620, 520, 1000, 620

function W:new(uid)
    local o = Base.new(self, 200, 140, 620, 520, "Relationship")
    o.uid = uid
    o.rsKey, o.minW, o.minH = "rel", 760, 560
    function o:onResized() if self.fitLayout then self:fitLayout(true) end end
    return o
end

function W:createChildren()
    Base.createChildren(self)
    local top = self:contentTop()
    self.portraitX, self.portraitY, self.portraitW, self.portraitH = 12, top, 150, 270
    self.model = nil
    -- 0.5.1.5: live body, else a stand-in from the saved look (Look.lua), else the last look as text
    if M.lookPortrait then pcall(M.lookPortrait, self) end
    if M.lookPortrait == nil then pcall(function() -- full-body 3D portrait like the character screen (B42 ISUI3DModel), if it takes the NPC
        if ISUI3DModel == nil then return end
        local shell = PA().Talk.shellFor(self.uid)
        if shell == nil then return end
        local m = ISUI3DModel:new(self.portraitX, self.portraitY, self.portraitW, self.portraitH)
        m:initialise()
        m:instantiate()
        m:setCharacter(shell)
        pcall(function() m:setState("idle") end)
        pcall(function() m:setDirection(IsoDirections.S) end)
        pcall(function() m:setIsometric(false) end)
        self:addChild(m)
        self.model = m
    end) end
    self.cx = 176
    T.tabs(self, self.cx, top + 92, W.TABS, function(win, i) win:showTab(i) end)
    local listY, listH = top + 120, self.height - top - 120 - 46
    self.memList = T.list(self, self.cx, listY, self.width - self.cx - 12, listH, 36, W.drawMemory)
    self.tieList = T.list(self, self.cx, listY, self.width - self.cx - 12, listH, 30, W.drawTie)
    self.intList = T.list(self, self.cx, listY, self.width - self.cx - 12, listH, 36, W.drawInteraction)
    local by = self.height - 36
    self.radioBtn = T.button(self, self.cx, by, 170, 26, ALifeTr("IGUI_ALCP_Btn_Contact_by_radio", "Contact by radio"), self, W.onRadio, S.green)
    self.closeBtn = T.button(self, self.width - 92, by, 80, 26, ALifeTr("IGUI_ALCP_Btn_Close", "Close"), self, W.close)
    self:refresh()
    self:showTab(M.settings.pageFirst == false and W.TAB.overview or W.TAB.personality)
end

function W:showTab(i)
    self.activeTab = i
    self.memList:setVisible(i == W.TAB.memories)
    self.tieList:setVisible(i == W.TAB.close)
    self.intList:setVisible(i == W.TAB.interactions)
    if self.setPageMode then self:setPageMode(i == W.TAB.personality) end
end

function W:refresh()
    self.data = M.relationshipData(self.uid, ALifeSide.you())
    if self.data == nil then
        -- 0.5.1.3 (user's idea): never leave the panel blank when nothing at all is known any more
        self.data = { uid = tostring(self.uid), name = "Someone", value = 0, label = "Unknown", band = "Unknown", why = "No data yet",
            rows = {}, interactions = {}, ties = {}, promises = {}, story = {}, away = true, dead = false,
            seen = { away = true, text = "Whereabouts unknown" } }
    end
    local d = self.data
    if M.lookPortrait and self.portraitW then pcall(M.lookPortrait, self) end -- 0.5.1.5: body loaded / unloaded since
    self.title = "Relationship - " .. d.name
    self.memList:clear()
    if #d.rows == 0 then self.memList:addItem("none", { kind = "event", text = "Nothing memorable yet.", when = "" }) end
    for _, row in ipairs(d.rows) do self.memList:addItem(row.text, row) end
    self.tieList:clear()
    if #(d.ties or {}) == 0 then self.tieList:addItem("none", { name = "No close ties known.", word = "", score = 0, none = true }) end
    for _, t in ipairs(d.ties or {}) do self.tieList:addItem(t.name, t) end
    self.intList:clear()
    local inter = d.interactions or {}
    if #inter == 0 then self.intList:addItem("none", { w = "No interactions logged yet.", t = "" }) end
    for i = #inter, 1, -1 do self.intList:addItem(inter[i].w, inter[i]) end
    local ok = d.radioOk
    self.radioBtn.enable = ok
    self.radioBtn:setTooltip(ok and "Talk over the walkie-talkie (type in chat)" or tostring(d.radioWhy))
    if M.radio ~= nil and M.radio.uid == self.uid then self.radioBtn:setTitle("End radio call"); self.radioBtn.enable = true
    else self.radioBtn:setTitle("Contact by radio") end
    self.refreshedAt = T.now()
    if self.ovBuild then pcall(function() self:ovBuild() end) end -- 0.5.2.7: Overview lines laid out here, not per frame
end

function W.drawMemory(list, y, item, alt)
    local row = item.item
    T.rowBack(list, y, item, alt)
    local c = S.kindColor[row.kind] or S.text
    list:drawRect(4, y + 6, 3, list.itemheight - 12, 1, c.r, c.g, c.b)
    local fh, lw = T.fontH(), list:getWidth() - 20 -- 0.5.2.5: second line under the first in any font; cut to the width
    list:drawText(S.kinds[row.kind] or tostring(row.kind or ""), 14, y + 3, c.r, c.g, c.b, 1, S.font)
    list:drawTextRight(tostring(row.when or ""), lw, y + 3, S.dim.r, S.dim.g, S.dim.b, 1, S.font)
    list:drawText(T.fit(tostring(row.text or ""), lw - 14), 14, y + 3 + fh, S.text.r, S.text.g, S.text.b, 1, S.font)
    return y + list.itemheight
end

function W.drawTie(list, y, item, alt)
    local t = item.item
    T.rowBack(list, y, item, alt)
    local a = t.dead and 0.5 or 1
    if t.none then list:drawText(t.name, 10, y + 7, S.dim.r, S.dim.g, S.dim.b, 1, S.font); return y + list.itemheight end
    -- 0.5.2.5: columns from the list width and the font (name ~30%, badge, bar, why)
    local lw = list:getWidth() - 20
    local c1 = math.floor(lw * 0.30)
    list:drawText(T.fit(t.name .. (t.dead and " (dead)" or ""), c1 - 14), 10, y + 7, S.text.r, S.text.g, S.text.b, a, S.font)
    local _, tc = M.bandOf(t.score)
    local word = T.fit(tostring(t.word), math.floor(lw * 0.24))
    local bw = T.badge(list, c1, y + 5, word, { r = tc.r, g = tc.g, b = tc.b }, a)
    local bx = c1 + bw + 10
    local barW = math.min(90, lw - bx - 60)
    if barW >= 30 then T.relBar(list, bx, y + 11, barW, 7, t.score, a); bx = bx + barW + 10 end
    if t.why and lw - bx > 30 then list:drawText(T.fit(tostring(t.why), lw - bx), bx, y + 7, S.dim.r, S.dim.g, S.dim.b, a, S.font) end
    return y + list.itemheight
end

function W.drawInteraction(list, y, item, alt)
    local r = item.item
    local mood = nil
    T.rowBack(list, y, item, alt)
    local fh, lw = T.fontH(), list:getWidth() - 20 -- 0.5.2.5
    list:drawText(M.whenText and M.whenText(r) or tostring(r.t or ""), 10, y + 3, S.dim.r, S.dim.g, S.dim.b, 1, S.font)
    if r.a and r.b then
        local d = r.b - r.a
        local c = d > 0 and S.green or (d < 0 and S.red or S.dim)
        local txt = (d > 0 and "+" or "") .. tostring(d) .. "  (" .. tostring(r.a) .. " > " .. tostring(r.b) .. ")"
        list:drawTextRight(txt, lw, y + 3, c.r, c.g, c.b, 1, S.font)
        if r.m1 and r.m2 and r.m1 ~= r.m2 then
            mood = tostring(r.m1) .. " > " .. tostring(r.m2)
            list:drawTextRight(mood, lw, y + 3 + fh, S.amber.r, S.amber.g, S.amber.b, 1, S.font)
        end
    end
    list:drawText(T.fit(tostring(r.w or ""), lw - 10 - (mood and (T.textW(mood) + 12) or 0)), 10, y + 3 + fh, S.text.r, S.text.g, S.text.b, 1, S.font)
    return y + list.itemheight
end

function W:prerender()
    Base.prerender(self)
    if T.now() - (self.refreshedAt or 0) > 2000 then pcall(function() self:refresh() end) end
    local d = self.data
    if d == nil then return end
    local a = self.fade
    local top = self:contentTop()
    -- portrait frame (+ silhouette when the 3D model is not available)
    T.box(self, self.portraitX, self.portraitY, self.portraitW, self.portraitH, S.panel, S.borderDim, a)
    local textLook = self.portraitMode == "text" and self.portraitLook ~= nil
    if self.model == nil or textLook or self.portraitMode == "none" then
        local cx, t0 = self.portraitX + self.portraitW / 2, self.portraitY + 30
        local c = { r = 0.22, g = 0.22, b = 0.24 }
        local sa = (textLook and 0.35 or 0.9) * a
        self:drawRect(cx - 18, t0, 36, 40, sa, c.r, c.g, c.b)
        self:drawRect(cx - 36, t0 + 46, 72, 100, sa, c.r, c.g, c.b)
        self:drawRect(cx - 50, t0 + 50, 12, 90, sa, c.r, c.g, c.b)
        self:drawRect(cx + 38, t0 + 50, 12, 90, sa, c.r, c.g, c.b)
        self:drawRect(cx - 32, t0 + 150, 26, 80, sa, c.r, c.g, c.b)
        self:drawRect(cx + 6, t0 + 150, 26, 80, sa, c.r, c.g, c.b)
    end
    -- 0.5.1.5: no body to draw -> the last captured look as text, and a "Last seen" tag in the box
    if textLook and M.lookLines then
        local ly = self.portraitY + 8
        self:drawText("Last look:", self.portraitX + 6, ly, S.dim.r, S.dim.g, S.dim.b, a, S.font)
        for _, line in ipairs(M.lookLines(self.portraitLook, 11)) do
            ly = ly + math.max(18, T.fontH() + 2)
            if ly + T.fontH() > self.portraitY + self.portraitH - 24 then break end -- 0.5.2.5: stays in the frame
            local s = line
            s = T.fit(s, self.portraitW - 12) -- 0.5.2.7: cached measure, ellipsis
            self:drawText(s, self.portraitX + 6, ly, S.text.r, S.text.g, S.text.b, a, S.font)
        end
    end
    if self.portraitMode ~= nil and self.portraitMode ~= "live" and M.lastSeenTag then
        local tag = M.lastSeenTag(self.uid)
        if self.portraitMode == "none" and self.portraitLook == nil then
            self:drawText("Look not seen yet", self.portraitX + 6, self.portraitY + self.portraitH - 40, S.dim.r, S.dim.g, S.dim.b, a, S.font)
        end
        tag = T.fit(tag, self.portraitW - 12) -- 0.5.2.7: cached measure, ellipsis
        self:drawRect(self.portraitX + 2, self.portraitY + self.portraitH - 22, self.portraitW - 4, 20, 0.7 * a, 0.08, 0.08, 0.1)
        self:drawText(tag, self.portraitX + 6, self.portraitY + self.portraitH - 20, S.blue.r, S.blue.g, S.blue.b, a, S.font)
    end
    -- under the portrait: mood, drinking, nemesis
    local py = self.portraitY + self.portraitH + 8
    local L = self.lay or {}
    local lh = math.max(18, T.fontH() + 2)
    local pw = (self.cx or 176) - self.portraitX - 6 -- 0.5.2.5: under-portrait lines cut to the portrait column
    -- 0.5.2.7 [pt255u]: the left column is a list of lines, each cut to the column, the romance line split at "|"
    -- (one person per line) and nothing below the bottom bar
    local leftBottom = self.height - ((self.lay and self.lay.bottom) or 46) - 4
    local rows = { { "Mood: " .. tostring(d.mood or "?"), S.text } }
    if d.drunk then rows[#rows + 1] = { "Drinking: " .. d.drunk, S.amber } end
    if d.nemesis then rows[#rows + 1] = { tostring(d.nemesis.label), S.red } end
    if d.love then -- 0.5.1: romance / rivalry with other NPCs
        local pink = { r = 0.86, g = 0.5, b = 0.62 }
        if M.settings.uiFixedSize ~= false then
            for part in string.gmatch(tostring(d.love) .. "  |  ", "(.-)%s+|%s+") do
                if part ~= "" then rows[#rows + 1] = { part, pink } end
            end
        else rows[#rows + 1] = { tostring(d.love), pink } end
    end
    for i, r in ipairs(rows) do
        local ly = py + lh * (i - 1)
        if ly + T.fontH() > leftBottom then break end
        self:drawText(T.fit(r[1], pw), self.portraitX, ly, r[2].r, r[2].g, r[2].b, a, S.font)
    end
    -- header block: name, role, relationship bar, badges
    local x, w = self.cx, self.width - self.cx - 12
    local nc = d.dead and S.dim or S.accent -- 0.5.1: the dead are muted
    -- 0.5.2.5 [pt252u]: rows from the font metrics (self.lay, UIBond fitLayout); every line cut to the window
    local yRole, yBar, yBadge = L.role or (top + 20), L.bar or (top + 42), L.badge or (top + 62)
    self:drawText(T.fit(d.name .. (d.dead and "  (deceased)" or ""), w, S.fontTitle), x, top - 2, nc.r, nc.g, nc.b, a, S.fontTitle)
    self:drawText(T.fit(tostring(d.role or "") .. (d.faction and ("  -  " .. tostring(d.faction)) or ""), w), x, yRole, S.dim.r, S.dim.g, S.dim.b, a, S.font)
    local _, color = M.bandOf(d.value)
    local vs = (d.value > 0 and "+" or "") .. tostring(d.value)
    T.relBar(self, x, yBar + 2, w - T.textW(vs, S.fontTitle) - 16, 12, d.value, a)
    self:drawTextRight(vs, x + w, yBar + 8 - math.floor(T.fontH(S.fontTitle) / 2), color.r, color.g, color.b, a, S.fontTitle)
    local bx = x
    bx = bx + T.badge(self, bx, yBadge, T.fit(d.band, math.floor(w / 3)), { r = color.r, g = color.g, b = color.b }, a) + 6
    if d.youTie then bx = bx + T.badge(self, bx, yBadge, T.fit(tostring(d.youTie), math.floor(w / 3)), S.blue, a) + 6 end
    if d.bite and not d.dead then -- 0.5.2.10 [pt270u]: a red BITTEN pill on every tab (Overview, Bond, Web ...)
        bx = bx + T.badge(self, bx, yBadge, "Bitten" .. (M.agoText and (" " .. M.agoText(d.bite.ageH)) or ""), { r = 0.9, g = 0.25, b = 0.22 }, a) + 6
    end
    local restW = x + w - bx - 4
    if d.dead and d.deceased and d.deceased.text then -- 0.5.1: cause and time
        self:drawText(T.fit(tostring(d.deceased.text), restW), bx + 4, yBadge + 2, S.dim.r, S.dim.g, S.dim.b, a, S.font)
    elseif d.seen and d.seen.away and d.seen.text and not d.dead then -- 0.5.1: offline (A-Life parked them far away)
        local st = tostring(d.seen.text)
        if string.sub(st, 1, 4) ~= "Away" then st = "Away - " .. st end -- 0.5.1.5: the book text already says "Away"
        self:drawText(T.fit(st, restW), bx + 4, yBadge + 2, S.blue.r, S.blue.g, S.blue.b, a, S.font)
    elseif d.lastTalked then
        local txt = T.fit("Last talked " .. tostring(d.lastTalked), restW - 14)
        self:drawText(txt, bx + 4, yBadge + 2, S.dim.r, S.dim.g, S.dim.b, a, S.font)
        if d.trend ~= 0 and bx + 18 + T.textW(txt) < x + w then T.arrow(self, bx + 10 + T.textW(txt), yBadge + 4, d.trend > 0, d.trend > 0 and S.green or S.red, a) end
    end
    T.drawTabs(self)
    if self.activeTab == W.TAB.overview then self:drawOverview(x, L.y0 or (top + 124), w, a) end
end

-- 0.5.2.5: Overview text, cut to the window and skipped once below the content area
local function ovText(win, s, x, y, r, g, b, a, font)
    if y + T.fontH(font) > (win.ovBottom or win.height) then return end
    win:drawText(T.fit(s, (win.ovRight or win.width) - x, font), x, y, r, g, b, a, font)
end
function W:drawOverviewOld(x, y, w, a)
    local d = self.data
    local p = d.persona
    local fh = T.fontH()
    -- 0.5.2.5 [pt252u]: nothing past the right edge or into the bottom bar (big fonts / long texts)
    self.ovRight, self.ovBottom = x + w, self.height - ((self.lay and self.lay.bottom) or 46) - 4
    if p then
        ovText(self, tostring(p.label), x, y, S.accent.r, S.accent.g, S.accent.b, a, S.font)
        y = y + fh + 6
        local bx = x
        for _, tr in ipairs(p.traits or {}) do
            if bx + T.textW(tr) + 12 <= x + w and y + T.fontH() + 4 <= self.ovBottom then bx = bx + T.badge(self, bx, y, tr, S.amber, a) + 6 end
        end
        y = y + fh + 12
        ovText(self, "Speech: " .. tostring(p.speech) .. "  (" .. tostring(p.speechHint) .. ")", x, y, S.text.r, S.text.g, S.text.b, a, S.font)
        y = y + fh + 2
        ovText(self, "Often says " .. tostring(p.phrase) .. "   |   " .. tostring(p.quirk), x, y, S.dim.r, S.dim.g, S.dim.b, a, S.font)
        y = y + fh + 2
        ovText(self, "Values: " .. tostring(p.values), x, y, S.green.r, S.green.g, S.green.b, a, S.font)
        y = y + fh + 2
        ovText(self, "Can't stand: " .. tostring(p.dislikes), x, y, S.red.r, S.red.g, S.red.b, a, S.font)
        y = y + fh + 12
    else -- 0.5.1.5: never an empty section
        ovText(self, "Personality: not much known yet.", x, y, S.dim.r, S.dim.g, S.dim.b, a, S.font)
        y = y + fh + 12
    end
    ovText(self, "What you know of their past", x, y, S.accent.r, S.accent.g, S.accent.b, a, S.font)
    y = y + fh + 4
    if #(d.story or {}) == 0 then
        ovText(self, "They haven't opened up to you yet.", x, y, S.dim.r, S.dim.g, S.dim.b, a, S.font)
        y = y + fh + 2
    end
    for _, bit in ipairs(d.story or {}) do
        for _, line in ipairs(wrapText(bit, w - 10)) do
            ovText(self, line, x + 6, y, S.text.r, S.text.g, S.text.b, a, S.font)
            y = y + fh + 1
        end
        y = y + 3
    end
    for _, l in ipairs(d.together or {}) do -- 0.5.2.10
        for _, line in ipairs(wrapText("Together: " .. l, w - 10)) do
            ovText(self, line, x + 6, y, 0.95, 0.7, 0.8, a, S.font)
            y = y + fh + 1
        end
    end
    if d.partnerLine then ovText(self, "Partner: " .. tostring(d.partnerLine), x, y + 4, 0.95, 0.55, 0.7, a, S.font); y = y + fh + 6 end
    if d.romance then
        y = y + 6
        local c = d.romance.stage >= 1 and { r = 0.95, g = 0.55, b = 0.7 } or S.dim
        ovText(self, (d.romance.stage >= 3 and "Partner" or "Romance") .. ": " .. tostring(d.romance.word)
            .. (d.romance.since and ("  (since day " .. tostring(d.romance.since) .. ")") or ""), x, y, c.r, c.g, c.b, a, S.font)
        y = y + fh + 2
    end
    if d.promises and #d.promises > 0 then
        y = y + 6
        ovText(self, "Your promises", x, y, S.accent.r, S.accent.g, S.accent.b, a, S.font)
        y = y + fh + 2
        for i, p in ipairs(d.promises) do
            if i > 3 then break end
            local c = p.state == "kept" and S.green or (p.state == "broken" and S.red or S.amber)
            ovText(self, "- " .. tostring(p.text) .. "  [" .. tostring(p.state) .. (p.due and (", " .. p.due) or "") .. "]",
                x + 6, y, c.r, c.g, c.b, a, S.font)
            y = y + fh + 1
        end
    end
    if d.why then
        y = y + 6
        ovText(self, "Latest: " .. string.sub(tostring(d.why), 1, 70), x, y, S.dim.r, S.dim.g, S.dim.b, a, S.font)
    end
end

-- 0.5.2.7 [pt255u]: the Overview is laid out ONCE (on refresh / resize / tab change) into lines with a y each, then
-- drawn every frame from that list inside the body (between the tab row and the bottom bar), clipped (stencil, and
-- only rows fully inside are drawn) and scrolled with the mouse wheel. Long backstory / many promises scroll.
function W:ovBuild()
    local d = self.data
    if d == nil then return end
    local x = self.cx or 176
    local w = self.width - x - 12 - 10 -- room for the scroll bar
    local fh = T.fontH()
    local out, y = {}, 0
    local function line(s, c, dx, gap) out[#out + 1] = { y = y, h = fh, s = T.fit(s, w - (dx or 0)), c = c, dx = dx or 0 }; y = y + fh + (gap or 2) end
    local function wrapped(s, c, dx)
        for _, ln in ipairs(wrapText(s, w - (dx or 0) - 4)) do line(ln, c, dx, 1) end
    end
    -- 0.5.2.7 [pt255u] (uiFancy): small uppercase gold section headers like the Personality page
    local fancy = M.settings.uiFancy ~= false and M.Fancy ~= nil
    local function head(s, gapBefore)
        if fancy then y = y + (gapBefore or 4); line(string.upper(s), M.Fancy.C.gold, 0, 6) else line(s, S.accent, 0, 4) end
    end
    local p = d.persona
    if p then
        if fancy then head("Personality", 0) end
        line(tostring(p.label), fancy and M.Fancy.C.name or S.accent, 0, 6)
        local bx, row = 0, {}
        for _, tr in ipairs(p.traits or {}) do
            local bw = T.textW(tr) + 12
            if bx > 0 and bx + bw > w then out[#out + 1] = { y = y, h = fh + 4, badges = row }; y = y + fh + 8; row, bx = {}, 0 end
            row[#row + 1] = { dx = bx, s = T.fit(tr, w - 12) }
            bx = bx + bw + 6
        end
        if #row > 0 then out[#out + 1] = { y = y, h = fh + 4, badges = row }; y = y + fh + 12 end
        wrapped("Speech: " .. tostring(p.speech) .. "  (" .. tostring(p.speechHint) .. ")", S.text, 0); y = y + 1
        wrapped("Often says " .. tostring(p.phrase) .. "   |   " .. tostring(p.quirk), S.dim, 0); y = y + 1
        wrapped("Values: " .. tostring(p.values), S.green, 0); y = y + 1
        wrapped("Can't stand: " .. tostring(p.dislikes), S.red, 0); y = y + 10
    else
        line("Personality: not much known yet.", S.dim, 0, 12)
    end
    head("What you know of their past", 2)
    if #(d.story or {}) == 0 then line("They haven't opened up to you yet.", S.dim, 0, 2) end
    for _, bit in ipairs(d.story or {}) do wrapped(bit, S.text, 6); y = y + 3 end
    if d.together and #d.together > 0 then -- 0.5.2.10 [pt270u]: the shared past with their partner
        y = y + 4
        head("Together", 2)
        for _, l in ipairs(d.together) do wrapped(l, { r = 0.95, g = 0.7, b = 0.8 }, 6); y = y + 2 end
    end
    if d.partnerLine then y = y + 4; wrapped("Partner: " .. tostring(d.partnerLine), { r = 0.95, g = 0.55, b = 0.7 }, 0) end
    if d.romance then
        y = y + 6
        local c = (tonumber(d.romance.stage) or 0) >= 1 and { r = 0.95, g = 0.55, b = 0.7 } or S.dim
        wrapped(((tonumber(d.romance.stage) or 0) >= 3 and "Partner" or ((tonumber(d.romance.stage) or 0) == 0 and "Toward you" or "Romance")) .. ": " .. tostring(d.romance.word)
            .. (d.romance.since and ("  (since day " .. tostring(d.romance.since) .. ")") or ""), c, 0)
    end
    if d.promises and #d.promises > 0 then
        y = y + 6
        head("Your promises", 0)
        for _, pr in ipairs(d.promises) do
            local c = pr.state == "kept" and S.green or (pr.state == "broken" and S.red or S.amber)
            wrapped("- " .. tostring(pr.text) .. "  [" .. tostring(pr.state) .. (pr.due and (", " .. pr.due) or "") .. "]", c, 6)
        end
    end
    if d.why then y = y + 6; wrapped("Latest: " .. tostring(d.why), S.dim, 0) end
    self.ovLines, self.ovTotal, self.ovW = out, y, w
    self.ovBuilds = (self.ovBuilds or 0) + 1
    self:ovClamp()
end
function W:ovView()
    local L = self.lay or {}
    local top = L.y0 or (self:contentTop() + 124)
    local bottom = self.height - (L.bottom or 46) - 4
    return top, math.max(0, bottom - top)
end
function W:ovClamp()
    local _, vh = self:ovView()
    local maxS = math.max(0, (self.ovTotal or 0) - vh)
    self.ovScroll = math.max(0, math.min(self.ovScroll or 0, maxS))
    return maxS
end
function W:drawOverview(x, y, w, a)
    if M.settings.uiFixedSize == false then return self:drawOverviewOld(x, y, w, a) end
    if self.ovLines == nil or self.ovW ~= self.width - x - 22 then self:ovBuild() end
    local top, vh = self:ovView()
    local sc = self.ovScroll or 0
    local bottom = top + vh
    self.ovRight, self.ovBottom = x + w, bottom
    pcall(function() self:setStencilRect(x - 2, top, w + 4, vh) end)
    for _, ln in ipairs(self.ovLines or {}) do
        local ly = top + ln.y - sc
        if ly >= top and ly + ln.h <= bottom then -- whole rows only: nothing over the buttons even without a stencil
            if ln.badges then
                for _, bd in ipairs(ln.badges) do T.badge(self, x + bd.dx, ly, bd.s, S.amber, a) end
            else
                self:drawText(ln.s, x + ln.dx, ly, ln.c.r, ln.c.g, ln.c.b, a, S.font)
            end
        elseif ly > bottom then break end
    end
    pcall(function() self:clearStencilRect() end)
    -- scroll bar when it doesn't all fit
    local total = self.ovTotal or 0
    if total > vh and vh > 20 then
        local bx = x + w - 6
        self:drawRect(bx, top, 4, vh, 0.25 * a, 0.5, 0.5, 0.5)
        local th = math.max(16, math.floor(vh * vh / total))
        local ty = top + math.floor((vh - th) * sc / math.max(1, total - vh))
        self:drawRect(bx, ty, 4, th, 0.8 * a, S.accent.r, S.accent.g, S.accent.b)
    end
end
function W:onMouseWheel(del)
    if not self.pageMode and self.activeTab == W.TAB.overview and M.settings.uiFixedSize ~= false then
        self.ovScroll = (self.ovScroll or 0) + (tonumber(del) or 0) * (T.fontH() + 2) * 3
        self:ovClamp()
        return true
    end
    return false
end

function W:onRadio()
    if M.radio ~= nil and M.radio.uid == self.uid then M.endRadio("Signing off.")
    elseif M.startRadio then M.startRadio(self.uid) end
    self:refresh()
end

function W:close()
    pcall(function() if self.model then self.model:setCharacter(nil) end end)
    Base.close(self)
    if M.relationWindow == self then M.relationWindow = nil end
end

function M.openRelationship(uid)
    if M.relationWindow ~= nil then pcall(function() M.relationWindow:close() end) end
    local w = W:new(tostring(uid))
    T.open(w)
    M.relationWindow = w
    return w
end

----------------------------------------------------------------------------------------------------------------
-- Master list: sort (opinion / name / last talked) + filter (all / friends / enemies / dead) + name search
----------------------------------------------------------------------------------------------------------------
ALifeTalkRelationList = Base:derive("ALifeTalkRelationList")
local L = ALifeTalkRelationList
L.SORTS = { "Opinion", "Name", "Recent" }
L.FILTERS = { "All", "Friends", "Enemies", "Dead" }

function L:new()
    local o = Base.new(self, 160, 120, 480, 520, "Relationships")
    o.sortBy, o.filterBy = 1, 1
    return o
end

function L:createChildren()
    Base.createChildren(self)
    local top = self:contentTop()
    self.sortBtn = T.button(self, 12, top, 130, 22, ALifeTr("IGUI_ALCP_Btn_Sort_Opinion", "Sort: Opinion"), self, L.onSort)
    self.filterBtn = T.button(self, 148, top, 120, 22, ALifeTr("IGUI_ALCP_Btn_Show_All", "Show: All"), self, L.onFilter)
    pcall(function()
        if ISTextEntryBox == nil then return end
        local e = ISTextEntryBox:new("", 276, top, self.width - 288, 22)
        e:initialise()
        e:instantiate()
        pcall(function() e:setTooltip("Search by name") end)
        self:addChild(e)
        self.search = e
    end)
    self.list = T.list(self, 12, top + 30, self.width - 24, self.height - top - 30 - 46, 42, L.drawRow)
    self.list:setOnMouseDoubleClick(self, L.onOpen)
    local by = self.height - 36
    self.openBtn = T.button(self, 12, by, 110, 26, ALifeTr("IGUI_ALCP_Btn_Open", "Open"), self, L.onOpenSelected)
    self.radioBtn = T.button(self, 128, by, 150, 26, ALifeTr("IGUI_ALCP_Btn_Contact_by_radio", "Contact by radio"), self, L.onRadio, S.green)
    self.setBtn = T.button(self, 284, by, 90, 26, ALifeTr("IGUI_ALCP_Btn_Settings", "Settings"), self, function() pcall(M.openSettings) end)
    self.closeBtn = T.button(self, self.width - 92, by, 80, 26, ALifeTr("IGUI_ALCP_Btn_Close", "Close"), self, L.close)
    self:refresh()
end

function L:onSort()
    self.sortBy = self.sortBy % #L.SORTS + 1
    self.sortBtn:setTitle("Sort: " .. L.SORTS[self.sortBy])
    self:refresh()
end
function L:onFilter()
    self.filterBy = self.filterBy % #L.FILTERS + 1
    self.filterBtn:setTitle("Show: " .. L.FILTERS[self.filterBy])
    self:refresh()
end

function M.filterSortNpcs(list, sortBy, filterBy, query)
    local out = {}
    query = string.lower(tostring(query or ""))
    for _, n in ipairs(list) do
        local keep = true
        if filterBy == 2 then keep = not n.dead and n.value >= 16
        elseif filterBy == 3 then keep = not n.dead and n.value <= -16
        elseif filterBy == 4 then keep = n.dead == true end
        if keep and query ~= "" and not string.find(string.lower(n.name), query, 1, true) then keep = false end
        if keep then out[#out + 1] = n end
    end
    table.sort(out, function(a, b)
        if sortBy == 2 then return a.name < b.name end
        if sortBy == 3 then return (a.lastN or 0) > (b.lastN or 0) end
        if a.dead ~= b.dead then return not a.dead end
        return a.value > b.value
    end)
    return out
end

function L:refresh()
    local selUid = nil
    local cur = self:selectedNpc()
    if cur then selUid = cur.uid end
    self.list:clear()
    local all = M.knownNpcs(ALifeSide.you())
    for _, n in ipairs(all) do
        if M.closeWithLine then n.close = M.closeWithLine(n.uid, ALifeSide.you()) end
        local inter = M.interactionsOf and M.interactionsOf(n.uid) or {}
        n.lastN = #inter > 0 and (inter[#inter].n or #inter) or 0
        n.last = #inter > 0 and inter[#inter].t or nil
        local okT, tie = false, nil
        if M.playerTie and n.record then okT, tie = pcall(M.playerTie, n.record, ALifeSide.you()) end
        n.tie = okT and tie or nil
        n.nem = M.nemesisOf and M.nemesisOf(n.uid) or nil
    end
    self.query = self.search and self.search:getText() or ""
    for i, n in ipairs(M.filterSortNpcs(all, self.sortBy, self.filterBy, self.query)) do
        self.list:addItem(n.name, n)
        if n.uid == selUid then self.list.selected = i end
    end
    local item, ok, why = M.findRadio(ALifeSide.you())
    self.radioOk = item ~= nil and ok
    self.radioBtn.enable = self.radioOk
    self.radioBtn:setTooltip(self.radioOk and "Call the selected person" or tostring(why or "You need a walkie-talkie"))
end

function L:prerender()
    Base.prerender(self)
    if self.search and self.search:getText() ~= self.query then pcall(function() self:refresh() end) end
    if #self.list.items == 0 then
        self:drawTextCentre("Nobody here yet.", self.width / 2, self.list:getY() + 30, S.dim.r, S.dim.g, S.dim.b, self.fade, S.font)
    end
end

function L.drawRow(list, y, item, alt)
    local n = item.item
    T.rowBack(list, y, item, alt)
    local band, c = M.bandOf(n.value)
    local a = n.dead and 0.5 or 1
    list:drawRect(4, y + 6, 3, list.itemheight - 12, a, c.r, c.g, c.b)
    list:drawText(n.name .. (n.dead and " (dead)" or ""), 14, y + 4, S.text.r, S.text.g, S.text.b, a, S.font)
    T.relBar(list, 200, y + 9, 120, 7, n.value, a)
    list:drawTextRight((n.value > 0 and "+" or "") .. tostring(n.value), 360, y + 4, c.r, c.g, c.b, a, S.font)
    if n.tie then T.badge(list, 368, y + 2, tostring(n.tie), n.nem and S.red or S.blue, a) end
    local seen = (not n.dead and M.lastSeenOf and not n.ghost) and M.lastSeenOf(n.uid, n.record) or nil
    local ghostText = (n.ghost and not n.dead and M.bookAwayText) and M.bookAwayText(n.uid) or nil
    local sub = n.nem and n.nem.label or ghostText or (seen and seen.away and seen.text and ("Away - " .. seen.text)) or n.close or (n.last and ("Last: " .. n.last)) or band
    list:drawText(string.sub(tostring(sub), 1, 64), 14, y + 22, n.nem and S.red.r or S.dim.r, n.nem and S.red.g or S.dim.g,
        n.nem and S.red.b or S.dim.b, a, S.font)
    return y + list.itemheight
end

function L:selectedNpc()
    if self.list == nil then return nil end
    local it = self.list.items[self.list.selected]
    return it and it.item or nil
end
function L:onOpen(n) if n then M.openRelationship(n.uid) end end
function L:onOpenSelected() local n = self:selectedNpc(); if n then M.openRelationship(n.uid) end end
function L:onRadio()
    local n = self:selectedNpc()
    if n == nil then return end
    local ok, why = M.radioCheck(ALifeSide.you(), n.uid)
    if not ok then pcall(function() ALifeSide.you():Say(why) end); return end
    T.confirm("Call " .. tostring(n.name) .. " on the walkie-talkie?", function() M.startRadio(n.uid) end)
end
function L:close()
    Base.close(self)
    if M.relationList == self then M.relationList = nil end
end

function M.openRelationList()
    if M.relationList ~= nil then pcall(function() M.relationList:close() end) end
    local w = L:new()
    T.open(w)
    M.relationList = w
    return w
end

----------------------------------------------------------------------------------------------------------------
-- Settings window (toggles saved to Zomboid/Lua/alifetalk_settings.txt)
----------------------------------------------------------------------------------------------------------------
local earlyRows = type(M.settingRows) == "table" and M.settingRows or {} -- pre-1.0: shared files load first and add rows early
M.settingRows = {
    { "ambient", "NPCs chat with each other near you" },
    { "opinionPopup", "Floating +N / -N opinion popup" },
    { "personaMods", "Personality changes how fast opinion moves" },
    { "interactionLog", "Keep a per-NPC interaction log" },
    { "nemesis", "Nemesis grudges and revenge visits" },
    { "radioNews", "AI-written Knox County news on the radio" },
    { "attackPlayer", "Hostile NPCs attack you at very low opinion (patch)" },
    { "attackNpc", "NPC enemies fight each other (patch)" },
    { "recruiting", "Recruit NPCs by persuasion" },
    { "interrogation", "Interrogation: real intel, lies and traps" },
    { "romance", "Slow-building romance" },
    { "promises", "Promises with due times" },
    { "betrayal", "Rare betrayals by greedy / lying NPCs" },
    -- 0.5.0
    { "emotions", "Emotions (decay, events, color their talk)" },
    { "darkPersonas", "Difficult / unhinged personalities (new NPCs)" },
    { "offscreenLives", "Off-screen lives: needs, stress, goals" },
    { "worldReactions", "React to gunfire, bodies, fire, weather..." },
    { "playerOrders", "Give orders to companions (follow, hold...)" },
    { "rumors", "Rumors about you spread NPC to NPC" },
    { "politics", "Faction politics: leaders, wars, truces" },
    { "quests", "Jobs from NPCs, checked by the game" },
    { "voice", "Voice: push-to-talk key + NPC voices (bridge)" },
    { "pageFirst", "Open NPC windows on the Personality page" },
    -- 0.5.1
    { "wounds", "NPCs feel and talk about their exact wounds" },
    { "bonds", "Relationships evolve on their own" },
    { "pairPopup", "Floating +N / -N for NPC-NPC bonds" },
    { "lastWords", "Last words of dying NPCs" },
    { "pauseListen", "'Wait!' / 'Stop!' makes NPCs pause and listen" },
    { "territory", "Territory warnings and 'leave my base'" },
    { "nameDiscovery", "Learn names from what NPCs say (fake names too)" },
    { "threats", "Intimidation: threats work by odds (or backfire)" },
    { "activity", "Daily life: sit, sleep, cook, guard, barricade..." },
    { "keepKnown", "Keep NPCs you know (no culling, same identity)" },
    { "turnedReact", "Reactions when a friend turns / is put down" },
    { "woundTalk", "NPCs mention their wounds unprompted" },
    { "woundTalkFreq", "Wound talk frequency (%)", { 0, 25, 50, 100, 200, 300 } },
    { "dreams", "Dreams, nightmares and PTSD flare-ups" },
    { "weatherTalk", "Weather and season talk, storm prep" },
    { "factionMemory", "Factions remember what you did to their rivals" },
    { "npcLove", "NPC romance, jealousy, breakups" },
    { "notes", "NPCs leave readable notes" },
    { "reputation", "Strangers have heard of you (titles)" },
    { "weirdFear", "Fear of the weird (fog, Backrooms, sewers, monsters)" },
    { "lifeTopics", "Varied talk: life before, music, jokes, gossip (anti-repeat)" },
    { "settlers", "NPCs can move into your base" },
    { "attention", "NPCs stop and face you when you talk" },
    { "listenWindowSec", "Listen window after you speak (s)", { 4, 6, 8, 10, 15, 20 } },
    { "listenDebug", "Log listen / hold decisions to console ([ALifeTalk][Listen])" },
    { "party", "Party: companions, Party window, commands" },
    { "partyCap", "Party size (above 6 needs beds, food and water, trust, seats)", { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 } },
    -- 0.8.2: the party's limits and what slots above the free part need (all yours to change)
    { "partyMax", "Party: the most it can ever be", { 4, 6, 8, 10, 12, 15 } },
    { "partyFree", "Party: size you get without beds / food / trust / seats", { 1, 2, 3, 4, 5, 6, 7, 8, 10 } },
    { "capBeds", "Party above the free size: needs a bed each at your base" },
    { "capFood", "Party above the free size: needs food stored at your base" },
    { "capWater", "...and water stored too" },
    { "capFoodDays", "Party: days of food (and water) your stores must hold", { 1, 2, 3, 5, 7, 14 } },
    { "capTrust", "Party above the free size: most of them must trust you" },
    { "capTrustShare", "Party: share of your people who must trust you (%)", { 25, 40, 50, 60, 75, 90, 100 } },
    { "capSeats", "Party above the free size: needs enough car seats near you" },
    { "cmdObey", "Commands: how likely someone does what you say when nothing else is known (%)", { 25, 50, 60, 75, 90, 100 } },
    { "outfitTalk", "NPCs react to what you wear and hold" },
    -- 0.5.1.3
    { "sideButtons", "Relationships / Party buttons in the left sidebar" },
    { "ownBehaviour", "Patch 1.4: NPCs you deal with stay put (A-Life gets them back on danger)" },
    { "partyOwn", "Patch 1.4: party members follow / hold exactly" },
    { "residentHold", "Patch 1.4: settlers stay at your base" },
    { "activityLog", "Log daily activities to console ([ALifeTalk][Activity])" },
    { "farProfiles", "Fill far-away people's pages from saved data (personality, ties, last seen)" },
    { "farLook", "Keep the full-body preview of far-away people (saved look)" },
}
do
    local have = {}
    for _, r in ipairs(M.settingRows) do have[r[1]] = true end
    for _, r in ipairs(earlyRows) do if type(r) == "table" and not have[r[1]] then M.settingRows[#M.settingRows + 1] = r; have[r[1]] = true end end
end
ALifeTalkSettings = Base:derive("ALifeTalkSettings")
local ST = ALifeTalkSettings
ST.PER_COL = 18 -- 0.5.1: columns grow automatically (3 when needed) instead of running off the window
local function colCount() return math.max(1, math.ceil(#M.settingRows / ST.PER_COL)) end
function ST:new()
    local sw = getCore():getScreenWidth()
    local cols = colCount()
    local rows = math.min(#M.settingRows, ST.PER_COL)
    local w = math.min(420 * cols, sw - 40)
    return Base.new(self, math.max(20, sw / 2 - w / 2), 100, w, 80 + rows * 28 + 40, "A-Life settings")
end
local function cellOf(i)
    local col = math.floor((i - 1) / ST.PER_COL)
    return col * 420, ((i - 1) % ST.PER_COL) * 28
end
-- a row is a toggle { key, label } or a cycle { key, label, { values } } (numbers; click = next value)
-- pre-1.0 (trip-ups): a clicked row is "touched" so Save keeps it for this world (M.sbKeepTouched), and in
-- multiplayer the change goes to the server (admin only; ALifeSettingsNet sends the real value back if refused).
local function settingSent(key, v)
    if M.sbTouch then M.sbTouch(key) end
    if type(ALifeSettingsNet) == "table" and type(ALifeSettingsNet.set) == "function" then pcall(ALifeSettingsNet.set, nil, key, v) end
end
function M.settingNext(row)
    local vals = row[3]
    if type(vals) ~= "table" then
        M.settings[row[1]] = not (M.settings[row[1]] ~= false)
        settingSent(row[1], M.settings[row[1]])
        return M.settings[row[1]]
    end
    local cur = tonumber(M.settings[row[1]]) or vals[1]
    local nxt = vals[1]
    for i, v in ipairs(vals) do if v == cur then nxt = vals[i % #vals + 1] end end
    M.settings[row[1]] = nxt
    settingSent(row[1], nxt)
    return nxt
end
function ST:createChildren()
    Base.createChildren(self)
    local top = self:contentTop()
    self.btns = {}
    for i, row in ipairs(M.settingRows) do
        local cx, cy = cellOf(i)
        local b = T.button(self, 12 + cx, top + cy, 56, 22, "", self, function()
            M.settingNext(row)
            if M.applySettings then pcall(M.applySettings) end
            self:sync()
        end)
        self.btns[i] = b
    end
    T.button(self, self.width - 184, self.height - 36, 84, 26, ALifeTr("IGUI_ALCP_Btn_Save", "Save"), self, function() pcall(M.saveSettingsFile); self:close() end, S.green)
    T.button(self, self.width - 92, self.height - 36, 80, 26, ALifeTr("IGUI_ALCP_Btn_Close", "Close"), self, ST.close)
    self:sync()
end
function ST:sync()
    for i, row in ipairs(M.settingRows) do
        if type(row[3]) == "table" then
            local v = tonumber(M.settings[row[1]]) or row[3][1]
            local name = nil
            if type(row[4]) == "table" then for k, x in ipairs(row[3]) do if x == v then name = row[4][k] end end end -- pre-1.0: named choices
            self.btns[i]:setTitle(tostring(name or v))
            T.styleButton(self.btns[i], (name or v > 0) and S.green or S.red)
        else
            local on = M.settings[row[1]] ~= false
            self.btns[i]:setTitle(on and "ON" or "OFF")
            T.styleButton(self.btns[i], on and S.green or S.red)
        end
    end
end
function ST:prerender()
    Base.prerender(self)
    local top = self:contentTop()
    for i, row in ipairs(M.settingRows) do
        local cx, cy = cellOf(i)
        self:drawText(row[2], 78 + cx, top + cy + 3, S.text.r, S.text.g, S.text.b, self.fade, S.font)
    end
end
function ST:close() Base.close(self); if M.settingsWindow == self then M.settingsWindow = nil end end
function M.openSettings()
    if M.settingsWindow ~= nil then pcall(function() M.settingsWindow:close() end) end
    M.settingsWindow = T.open(ST:new())
    return M.settingsWindow
end

----------------------------------------------------------------------------------------------------------------
-- Radio status bar (top centre; End button)
----------------------------------------------------------------------------------------------------------------
ALifeTalkRadioBar = Base:derive("ALifeTalkRadioBar")
local R = ALifeTalkRadioBar
function R:new()
    local sw = getCore():getScreenWidth()
    local o = Base.new(self, sw / 2 - 170, 8, 340, 34, "")
    return o
end
function R:createChildren()
    self.endBtn = T.button(self, 276, 5, 56, 24, ALifeTr("IGUI_ALCP_Btn_End", "End"), self, function() M.endRadio("Signing off.") end, S.red)
end
function R:prerender()
    local t = T.now() - (self.openedAt or 0)
    self.fade = math.max(0, math.min(1, t / S.fadeMs))
    T.box(self, 0, 0, self.width, self.height, S.bg, S.border, self.fade)
    local tex = T.icon("radio")
    if tex then self:drawTextureScaled(tex, 8, 5, 24, 24, self.fade, 1, 1, 1) end
    local name = M.radio and M.radio.name or "?"
    local blink = math.floor(T.now() / 600) % 2 == 0
    self:drawText("On air with " .. tostring(name) .. " - type in chat", 38, 9, S.radio.r, S.radio.g, S.radio.b, self.fade, S.font)
    if blink then self:drawRect(266, 14, 5, 5, self.fade, S.red.r, S.red.g, S.red.b) end
end
function M.showRadioIndicator()
    if M.radioBar ~= nil then return end
    M.radioBar = T.open(R:new())
end
function M.hideRadioIndicator()
    if M.radioBar == nil then return end
    M.radioBar:setVisible(false)
    M.radioBar:removeFromUIManager()
    M.radioBar = nil
    if M.relationWindow then pcall(function() M.relationWindow:refresh() end) end
end

-- right-click anywhere: master list + settings (the per-NPC entries are added next to "Talk to" in ALifeLLMTalk_Main)
if type(Events) == "table" and Events.OnFillWorldObjectContextMenu then
    ALifeRadial.addFiller("relationships", "windows", function(playerNum, context, worldobjects, test)   -- 0.5.11: radial registry
        if test == true or not M.settings.enabled or type(context) ~= "table" or type(context.addOption) ~= "function" then return end
        if M.settings.immersive == true then return end   -- Chat Plus merge: no Relationships menu in immersive mode
        pcall(function() T.menuOption(context, "A-Life: Relationships...", nil, function() pcall(M.openRelationList) end, "heart") end)
    end)
end

return M
