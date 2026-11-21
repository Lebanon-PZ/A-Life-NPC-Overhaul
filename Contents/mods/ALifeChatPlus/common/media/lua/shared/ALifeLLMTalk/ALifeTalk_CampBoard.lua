-- ALifeTalk_CampBoard.lua (0.5.10): the camp board. One window with the whole camp at a glance.
-- Camp > Camp board. Every person: their job, what they're doing right now, how they're holding up (in words,
-- never a number), and anything that matters (bitten, hurt, grieving, saw you break a rule).
-- Above them: the camp (alarm, food, water, dinner, rules) and what happened today.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("ui", "ALifeTalk_CampBoard") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeTalk_Camp"
local M = ALifeLLMTalk
if type(M) ~= "table" or type(M.cpAddJob) ~= "function" then return end
local H = M.cpH

local DOING = {
    watch = "on night watch", patrol = "walking the patrol", haul = "hauling supplies", harvest = "bringing in the harvest",
    water = "watering the crops", meal = "cooking dinner", arm = "at the armory", quarantine = "in quarantine",
    evening = "by the fire", animals = "with the animals", sickbay = "going to the sick bay", medic = "treating someone",
}
-- unrest (0..100, the daily morale model) as words
function M.bdMood(uid)
    local st = M.store and M.store() or {}
    local u = type(st.unrest) == "table" and st.unrest[tostring(uid)] or nil
    local v = u and tonumber(u.v) or 0
    if u and u.left then return "gone", 0.6, 0.6, 0.6 end
    if v < 10 then return "content", 0.6, 0.85, 0.55 end
    if v < 25 then return "getting by", 0.85, 0.85, 0.7 end
    if v < 45 then return "fed up", 0.95, 0.7, 0.35 end
    return "close to leaving", 0.95, 0.4, 0.3
end
function M.bdDoing(uid, player)
    uid = tostring(uid)
    if H.fn(M, "alOn") and M.alOn() and not (H.fn(M, "cbKnown") and M.cbKnown(uid)) then
        local _, kind = M.alSpot(uid, player)
        return kind == "post" and "at their post" or (kind == "armory" and "at the armory" or "in the safe room")
    end
    local j = M.cpJobs[uid]
    if j then return DOING[j.kind] or j.kind end
    return "free"
end
function M.bdNotes(uid, player)
    uid = tostring(uid)
    local out = {}
    local d = M.cpData()
    if H.fn(M, "cbData") then
        local b = M.cbData().bit[uid]
        if type(b) == "table" and b.known then out[#out + 1] = b.mercy and "bitten, asked you to do it" or "bitten" end
    end
    if H.fn(M, "mdScore") and M.mdScore(uid) > 0 then
        local s = {}
        pcall(function() s = M.woundState(uid) end)
        out[#out + 1] = (s.bleeding or 0) > 0 and "bleeding" or (s.fracture and "broken bone" or "hurt")
    end
    if H.fn(M, "grData") and H.fn(M, "grHow") then
        local worst, who = 0, nil
        for _, e in ipairs(M.grData().dead) do local v = M.grHow(uid, e.uid); if v > worst then worst, who = v, e.name end end
        if who and worst > 0.3 then out[#out + 1] = "grieving " .. who end
    end
    local hy = type(d.hypo) == "table" and d.hypo[uid] or nil
    if type(hy) == "table" and H.hours() - (tonumber(hy.h) or 0) < 72 then out[#out + 1] = "saw you break a rule" end
    if H.fn(M, "cpWatcher") and M.cpWatcher(player) == uid then out[#out + 1] = "has the watch tonight" end
    return out
end
local function rgb(r, g, b) return string.format(" <RGB:%s,%s,%s> ", tostring(math.floor(r * 100) / 100), tostring(math.floor(g * 100) / 100), tostring(math.floor(b * 100) / 100)) end
local function camp(player)
    local lines = {}
    local d = M.cpData()
    local day = math.floor(H.hours() / 24) + 1
    lines[#lines + 1] = "Day " .. day .. (H.fn(M, "alOn") and M.alOn() and ("  " .. rgb(1, 0.4, 0.3) .. "ALARM UP" .. rgb(0.9, 0.88, 0.82)) or "")
    -- 0.8.8 UI: the ration rule, the food in words, who runs things while you're away (ALifeTalk_SettlementUI)
    if H.fn(ALifeSettlement, "statusLines") then
        local ok, st = pcall(ALifeSettlement.statusLines, player)
        if ok and type(st) == "table" then for _, l in ipairs(st) do lines[#lines + 1] = rgb(1, 0.93, 0.8) .. l .. rgb(0.9, 0.88, 0.82) end end
    end
    -- food: stored food against what dinner takes
    local st = nil
    if H.fn(M, "baseState") then pcall(function() st = M.baseState(player) end) end
    if type(st) == "table" and st.food then
        local per = nil
        if H.fn(M, "ckNeed") then local cooks = M.cpWithRole("cook", player); if cooks[1] then per = M.ckNeed(cooks[1], player) end end
        if st.guess and H.fn(M, "foodGuessWords") then lines[#lines + 1] = "Food: " .. tostring(M.foodGuessWords(st)) .. " (you're away)" -- pre-1.0
        else lines[#lines + 1] = "Food: " .. st.food .. " in your stores" .. (per and per > 0 and (", about " .. math.floor(st.food / per) .. " days of dinners") or "") end
    end
    if H.fn(M, "ckData") then
        local k = M.ckData()
        if k.fedQ and H.hours() - (tonumber(k.fedAt) or -1e9) < 24 then lines[#lines + 1] = "Dinner: " .. (k.fedQ >= 1 and "a good one" or "thin")
        elseif k.missedAt and H.hours() - k.missedAt < 24 then lines[#lines + 1] = "Dinner: " .. rgb(0.95, 0.5, 0.35) .. "none" .. rgb(0.9, 0.88, 0.82) end
    end
    -- water at the farm's water spot
    local w = H.fn(M, "cpFarmData") and M.cpFarmData().water or nil
    if w then
        local have = nil
        local sq = H.sqAt(w.x, w.y, w.z)
        if sq then pcall(function() local objs = sq:getObjects(); for i = 0, objs:size() - 1 do local a = tonumber(objs:get(i):getFluidAmount()); if a and (have == nil or a > have) then have = a end end end) end
        if have then lines[#lines + 1] = "Water: " .. math.floor(have) .. " L at the water spot" end
    end
    local rules = {}
    for _, r in ipairs(M.cpRules) do if d.rules[r.id] then rules[#rules + 1] = r.label end end
    if H.fn(M, "cbRule") then rules[#rules + 1] = "The bitten: " .. string.lower(M.cbRuleLabel[M.cbRule()] or "") end
    if #rules > 0 then lines[#lines + 1] = "Rules: " .. table.concat(rules, "; ") end
    return lines
end
-- the whole board as rich text (the window shows exactly this)
function M.bdText(player)
    local t = { " <H1> Camp board <TEXT> <LINE> ", rgb(0.9, 0.88, 0.82) }
    for _, l in ipairs(camp(player)) do t[#t + 1] = l .. " <LINE> " end
    t[#t + 1] = " <LINE> <H2> People <TEXT> <LINE> "
    local people = M.cpPeople(player)
    if #people == 0 then t[#t + 1] = rgb(0.7, 0.7, 0.7) .. "Nobody lives at your base yet. <LINE> " end
    for _, uid in ipairs(people) do
        local mood, r, g, b = M.bdMood(uid)
        local roleId = M.cpRoleOf(uid)
        local role = M.cpRoleLabel[roleId] or "General"
        -- 0.8.8 UI: how good they've got at it, in words
        if H.fn(ALifeSettlement, "roleCue") then
            local ok, cue = pcall(ALifeSettlement.roleCue, uid, roleId)
            if ok and type(cue) == "string" then role = role .. ", " .. cue end
        end
        t[#t + 1] = rgb(1, 0.93, 0.8) .. H.firstName(uid) .. rgb(0.7, 0.68, 0.62) .. "  " .. role .. "; " .. M.bdDoing(uid, player) .. "  " .. rgb(r, g, b) .. mood
        local notes = M.bdNotes(uid, player)
        if H.fn(M, "ckWhy") then local okw, why = pcall(M.ckWhy, uid, player); if okw and type(why) == "string" then notes[#notes + 1] = why end end
        if #notes > 0 then t[#t + 1] = rgb(0.95, 0.6, 0.45) .. "  (" .. table.concat(notes, ", ") .. ")" end
        t[#t + 1] = " <LINE> "
    end
    local today = H.fn(M, "cpToday") and M.cpToday(24) or {}
    if #today > 0 then
        t[#t + 1] = " <LINE> <H2> Today <TEXT> <LINE> " .. rgb(0.78, 0.76, 0.7)
        for i = #today, math.max(1, #today - 7), -1 do t[#t + 1] = today[i].t .. " <LINE> " end
    end
    -- 0.8.8 UI: the lieutenant's reports, scouts, the door (kept in the save, newest first)
    if H.fn(ALifeSettlement, "logText") then
        local ok, lg = pcall(ALifeSettlement.logText)
        if ok and type(lg) == "string" and lg ~= "" then t[#t + 1] = " <LINE> <H2> What happened <TEXT> <LINE> " .. rgb(0.78, 0.76, 0.7) .. lg end
    end
    return table.concat(t)
end
-- 0.8.8 UI: the camp board's buttons (stand down, per lieutenant): { label, fn }, and a signature to rebuild them on change
function M.bdActions(player)
    local out = {}
    if not H.fn(ALifeSettlement, "standButtons") then return out end
    local ok, list = pcall(ALifeSettlement.standButtons)
    for _, b in ipairs(ok and list or {}) do
        out[#out + 1] = { label = b.label, fn = function() pcall(ALifeSettlement.standDown, player or ALifeSide.you(), b.uid) end }
    end
    return out
end
function M.bdActionSig()
    if not H.fn(ALifeSettlement, "standSig") then return "" end
    local ok, s = pcall(ALifeSettlement.standSig)
    return ok and tostring(s) or ""
end

-- the window (vanilla ISCollapsableWindow + ISRichTextPanel)
M.bdUI = nil
function M.bdOpen(player)
    if type(ISCollapsableWindow) ~= "table" or type(ISRichTextPanel) ~= "table" then return false end
    if ALifeCampBoard == nil then
        ALifeCampBoard = ISCollapsableWindow:derive("ALifeCampBoard")
        function ALifeCampBoard:createChildren()
            ISCollapsableWindow.createChildren(self)
            local th = self:titleBarHeight()
            self.body = ISRichTextPanel:new(0, th, self.width, self.height - th - 8)
            self.body:initialise()
            self.body.background = false
            self.body.autosetheight = false
            self.body.clip = true
            self.body.marginLeft, self.body.marginRight = 14, 14
            self:addChild(self.body)
            self.body:addScrollBars()
            self.btns = {}
            self:buildButtons()
            self:refresh()
        end
        -- 0.8.8 UI: a row of buttons under the title (stand down, per lieutenant); rebuilt when the lieutenants change
        function ALifeCampBoard:buildButtons()
            for _, b in ipairs(self.btns or {}) do pcall(function() self:removeChild(b) end) end
            self.btns = {}
            self.sig = H.fn(M, "bdActionSig") and M.bdActionSig() or ""
            local acts = H.fn(M, "bdActions") and M.bdActions(ALifeSide.you()) or {}
            local x, th = 10, self:titleBarHeight()
            local fh = getTextManager():getFontHeight(UIFont.Small) + 6
            for _, a in ipairs(acts) do
                local w = getTextManager():MeasureStringX(UIFont.Small, a.label) + 16
                local b = ISButton:new(x, th + 4, w, fh, a.label, self, function() a.fn(); self:refresh() end)
                b:initialise(); b:instantiate()
                self:addChild(b)
                self.btns[#self.btns + 1] = b
                x = x + w + 6
            end
            self.btnH = #self.btns > 0 and (fh + 8) or 0
        end
        function ALifeCampBoard:refresh()
            local ok, txt = pcall(M.bdText, ALifeSide.you())
            self.body.text = ok and txt or (" <RED> " .. tostring(txt))
            self.body:paginate()
            self.lastAt = getTimestampMs()
        end
        function ALifeCampBoard:update()
            ISCollapsableWindow.update(self)
            if H.fn(M, "bdActionSig") and M.bdActionSig() ~= self.sig then pcall(self.buildButtons, self) end
            if getTimestampMs() - (self.lastAt or 0) > 2000 then self:refresh() end
            local top = self:titleBarHeight() + (self.btnH or 0)
            self.body:setY(top)
            self.body:setWidth(self.width)
            self.body:setHeight(self.height - top - 8)
        end
        function ALifeCampBoard:close()
            ISCollapsableWindow.close(self)
            self:removeFromUIManager()
            M.bdUI = nil
        end
    end
    if M.bdUI then M.bdUI:close() end
    local w, h = 560, math.min(640, getCore():getScreenHeight() - 120)
    local ui = ALifeCampBoard:new((getCore():getScreenWidth() - w) / 2, 80, w, h)
    ui:setTitle("Camp board")
    ui:initialise()
    ui:addToUIManager()
    ui:setResizable(true)
    M.bdUI = ui
    return true
end

M.cpMenus = M.cpMenus or {}
table.insert(M.cpMenus, 1, function(child, off, player, x, y, z, inRange, why, sub)
    local open = function() if not M.bdOpen(player) then H.halo("The camp board needs the game's UI.") end end
    if sub then sub:addOption(ALifeTr("IGUI_ALCP_Menu_Camp_board", "Camp board"), nil, open) else child("Camp board"):addOption(ALifeTr("IGUI_ALCP_Menu_Open_the_camp_board", "Open the camp board"), nil, open) end
end)

-- pre-1.0 MP (P4): the board on an MP client. The text and the stand-down buttons are built on the server (where the
-- camp, the registry and the lieutenants are) and shared ("ALifeChatPlus_CampBoardView"); a button = M.cpAct
-- "standDown" on the server as the sender. Single player / server: the functions above, unchanged.
M.CB_VIEW = "ALifeChatPlus_CampBoardView"
local textHere, actsHere, sigHere = M.bdText, M.bdActions, M.bdActionSig
local function mpClient() return type(ALifeSide) == "table" and ALifeSide.mpClient() end
local function boardView() return type(ALifeRemote) == "table" and ALifeRemote.shared(M.CB_VIEW) or nil end
function M.bdBoardBuild()
    local p = H.thePlayer()
    local acts = {}
    if H.fn(ALifeSettlement, "standButtons") then
        local ok, list = pcall(ALifeSettlement.standButtons)
        for _, b in ipairs(ok and type(list) == "table" and list or {}) do acts[#acts + 1] = { label = tostring(b.label), uid = tostring(b.uid) } end
    end
    local ok, txt = pcall(textHere, p)
    return { text = ok and tostring(txt) or "", sig = sigHere(), acts = acts }
end
function M.bdText(player)
    if mpClient() then local v = boardView(); return v and type(v.text) == "string" and v.text or " <TEXT> ..." end
    return textHere(player)
end
function M.bdActions(player)
    if mpClient() then
        local out, v = {}, boardView()
        for _, a in ipairs(v and type(v.acts) == "table" and v.acts or {}) do
            local uid = tostring(a.uid)
            out[#out + 1] = { label = tostring(a.label), fn = function() M.cpAct("standDown", uid, nil, nil, nil, nil, player) end }
        end
        return out
    end
    return actsHere(player)
end
function M.bdActionSig()
    if mpClient() then local v = boardView(); return v and tostring(v.sig or "") or "" end
    return sigHere()
end
M.cpActs = M.cpActs or {}
M.cpActs.standDown = function(player, uid)
    if not H.fn(ALifeSettlement, "standDown") or uid == nil then return false end
    local ok, res = pcall(ALifeSettlement.standDown, player, tostring(uid))
    return ok and res == true
end
require "ALifeNPCOverhaul/ALifeRemote"
if type(ALifeRemote) == "table" then ALifeRemote.share(M.CB_VIEW, M.bdBoardBuild) end
