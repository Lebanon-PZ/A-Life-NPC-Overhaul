-- A-Life Talk 0.4.0: floating opinion popup. When an NPC's opinion of the player changes (talk, gift, plea, insult,
-- overheard, A-Life deeds) a "+2" (green) / "-7" (red) and a mini relationship bar float above their head for ~3 s,
-- then fade. Screen space: one small UIElement per popup, moved every frame to the NPC's projected head position.
require "ALifeLLMTalk/ALifeLLMTalk_Main"
require "ALifeLLMTalk/ALifeLLMTalk_Theme"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Popup"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Popup") end end -- 0.5.1.6 perf label
require "ISUI/ISUIElement"

local M = ALifeLLMTalk
if type(M) ~= "table" or ISUIElement == nil then return end
local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, name) return type(t) == "table" and type(t[name]) == "function" end

M.popupSettings = { lifeMs = 3000, fadeMs = 700, risePx = 22, maxTiles = 30, max = 6 }
M.popups = {}

-- world -> screen (handles zoom); nil when it can't be projected
function M.worldToScreen(x, y, z, playerNum)
    playerNum = playerNum or 0
    local sx, sy = nil, nil
    if type(isoToScreenX) == "function" and type(isoToScreenY) == "function" then
        pcall(function() sx, sy = isoToScreenX(playerNum, x, y, z), isoToScreenY(playerNum, x, y, z) end)
    end
    if sx == nil and IsoUtils ~= nil then
        pcall(function()
            local zoom = getCore():getZoom(playerNum)
            sx = (IsoUtils.XToScreen(x, y, z, 0) - IsoCamera.getOffX()) / zoom + getPlayerScreenLeft(playerNum)
            sy = (IsoUtils.YToScreen(x, y, z, 0) - IsoCamera.getOffY()) / zoom + getPlayerScreenTop(playerNum)
        end)
    end
    return sx, sy
end

ALifeTalkOpinionPopup = ISUIElement:derive("ALifeTalkOpinionPopup")
local P = ALifeTalkOpinionPopup

function P:new(shell, delta, value)
    local o = ISUIElement.new(self, -200, -200, 96, 34)
    o.shell, o.delta, o.value = shell, delta, value
    o.born = M.Theme.now()
    o.anchorAlwaysOnTop = true
    return o
end

function P:initialise()
    ISUIElement.initialise(self)
    -- v0.4.2: javaObject does not exist yet here (it is made by instantiate); 0.4.1 logged an exception per popup
    if self.javaObject ~= nil and self.javaObject.setConsumeMouseEvents ~= nil then
        pcall(function() self.javaObject:setConsumeMouseEvents(false) end)
    end
    pcall(function() self:setAlwaysOnTop(true) end)
end

function P:prerender()
    local S, T = M.UIStyle, M.Theme
    local age = T.now() - self.born
    local life = M.popupSettings.lifeMs
    if age > life or self.shell == nil then self:kill(); return end
    local x, y, z = nil, nil, nil
    pcall(function() x, y, z = self.shell:getX(), self.shell:getY(), self.shell:getZ() end)
    if x == nil then self:kill(); return end
    local sx, sy = M.worldToScreen(x, y, z, 0)
    if sx == nil then self:setVisible(false); return end
    local zoom = 1
    pcall(function() zoom = getCore():getZoom(0) end)
    local rise = M.popupSettings.risePx * (age / life)
    self:setX(sx - self.width / 2)
    self:setY(sy - 150 / zoom - rise - (self.stack or 0) * 36)
    local a = 1
    if age < 150 then a = age / 150 elseif age > life - M.popupSettings.fadeMs then a = (life - age) / M.popupSettings.fadeMs end
    a = math.max(0, math.min(1, a))
    local c = self.delta > 0 and S.green or S.red
    local txt = (self.delta > 0 and "+" or "") .. tostring(math.floor(self.delta + (self.delta > 0 and 0.5 or -0.5)))
    if self.pair then -- 0.5.1: NPC <-> NPC bond: slimmer, bluish frame, a link mark and the other one's name
        T.box(self, 0, 0, self.width, self.height, { a = 0.5, r = 0.03, g = 0.05, b = 0.08 }, { a = 0.55, r = 0.45, g = 0.62, b = 0.85 }, a)
        self:drawRectBorder(5, 5, 8, 6, a, 0.55, 0.7, 0.9) -- a small chain link mark
        self:drawRectBorder(10, 8, 8, 6, a, 0.55, 0.7, 0.9)
        self:drawTextCentre(txt, self.width / 2, 1, c.r, c.g, c.b, a, S.font)
        local nm = tostring(self.pair)
        if #nm > 14 then nm = string.sub(nm, 1, 13) .. "." end
        self:drawTextCentre(nm, self.width / 2, 15, 0.7, 0.75, 0.82, a * 0.9, S.fontSmall or S.font)
        T.relBar(self, 8, self.height - 7, self.width - 16, 4, self.value, a)
        return
    end
    T.box(self, 0, 0, self.width, self.height, { a = 0.55, r = 0.04, g = 0.04, b = 0.05 }, { a = 0.6, r = c.r, g = c.g, b = c.b }, a)
    self:drawTextCentre(txt, self.width / 2, 1, c.r, c.g, c.b, a, S.fontTitle or S.font)
    T.relBar(self, 8, self.height - 9, self.width - 16, 5, self.value, a)
end

function P:render() end

function P:kill()
    self.dead = true
    self:setVisible(false)
    self:removeFromUIManager()
end

-- Chat Plus merge, immersive mode: no numbers. A noticeable change shows as a vague read of them instead,
-- over your head, the way you'd notice it: "She seems to warm up to you." / "He doesn't seem to like you."
M.vibe = M.vibe or { last = {} }
M.vibeLines = {
    up = { "%s seems to warm up to you.", "%s relaxes a little.", "%s seems less wary of you." },
    upBig = { "%s seems to really appreciate that.", "Something in %s's face softens." },
    down = { "%s doesn't seem to like that.", "%s eyes you warily.", "%s seems put off." },
    downBig = { "%s looks at you with open dislike.", "%s doesn't trust you at all now." },
}
function M.showVibe(uid, delta)
    delta = tonumber(delta) or 0
    if math.abs(delta) < 2 or not M.isSP() then return end
    local now = M.Theme and M.Theme.now and M.Theme.now() or 0
    local key = tostring(uid)
    if now - (M.vibe.last[key] or -1e12) < 20000 then return end     -- not after every line
    local pa = PA()
    local shell = fn(pa.Talk, "shellFor") and pa.Talk.shellFor(key) or nil
    local player = ALifeSide.you()
    if shell == nil or player == nil then return end
    local near = false
    pcall(function() near = (shell:getX() - player:getX()) ^ 2 + (shell:getY() - player:getY()) ^ 2 <= 15 * 15 end)
    if not near then return end
    local name = "They"
    pcall(function()
        -- pre-1.0: only a name you were given (shownName: "Stranger" / unknown = "They"), and only the first name
        local n, known = nil, false
        if fn(M, "shownName") then n, known = M.shownName(key, player) end
        if known and n and n ~= "" then name = string.match(tostring(n), "^(%S+)") or tostring(n) end
    end)
    local list = delta >= 8 and M.vibeLines.upBig or delta > 0 and M.vibeLines.up
        or delta <= -8 and M.vibeLines.downBig or M.vibeLines.down
    M.vibe.last[key] = now
    local line = string.format(list[ZombRand(#list) + 1], name)
    pcall(ALifeLetter, player, line, delta > 0 and 170 or 220, delta > 0 and 210 or 150, delta > 0 and 170 or 140)
end

function M.showOpinionPopup(uid, delta, value)
    if M.settings.immersive == true then return M.showVibe(uid, delta) end
    if M.settings.opinionPopup == false or not M.isSP() then return end
    delta = tonumber(delta) or 0
    if math.abs(delta) < 0.5 then return end
    local pa = PA()
    local shell = fn(pa.Talk, "shellFor") and pa.Talk.shellFor(tostring(uid)) or nil
    if shell == nil then return end
    local player = ALifeSide.you()
    if player ~= nil then
        local dx, dy = 1e9, 1e9
        pcall(function() dx, dy = shell:getX() - player:getX(), shell:getY() - player:getY() end)
        if dx * dx + dy * dy > M.popupSettings.maxTiles ^ 2 then return end
    end
    -- same NPC within the life time: merge into one popup (sum)
    for _, p in ipairs(M.popups) do
        if not p.dead and p.uid == tostring(uid) and M.Theme.now() - p.born < M.popupSettings.lifeMs - 800 then
            p.delta, p.value, p.born = p.delta + delta, value, M.Theme.now()
            return p
        end
    end
    local p = P:new(shell, delta, value)
    p.uid = tostring(uid)
    p:initialise()
    p:addToUIManager()
    local live = 0
    for _, q in ipairs(M.popups) do if not q.dead and q.shell == shell then live = live + 1 end end
    p.stack = live
    M.popups[#M.popups + 1] = p
    while #M.popups > M.popupSettings.max do
        local old = table.remove(M.popups, 1)
        if old and not old.dead then pcall(function() old:kill() end) end
    end
    return p
end

-- 0.5.1: NPC <-> NPC bond popup over the listener ('value' = the pair score -100..100); own toggle
function M.showPairPopup(listenerUid, otherName, delta, value)
    if M.settings.opinionPopup == false or M.settings.pairPopup == false or not M.isSP() then return end
    delta = tonumber(delta) or 0
    if math.abs(delta) < 0.5 then return end
    local pa = PA()
    local shell = fn(pa.Talk, "shellFor") and pa.Talk.shellFor(tostring(listenerUid)) or nil
    local player = ALifeSide.you()
    if shell == nil or player == nil then return end
    local dx, dy = 1e9, 1e9
    pcall(function() dx, dy = shell:getX() - player:getX(), shell:getY() - player:getY() end)
    if dx * dx + dy * dy > M.popupSettings.maxTiles ^ 2 then return end
    local p = P:new(shell, delta, value)
    p.uid, p.pair = tostring(listenerUid) .. "#pair", tostring(otherName or "someone")
    p.width, p.height = 104, 34
    p:initialise()
    p:addToUIManager()
    local live = 0
    for _, q in ipairs(M.popups) do if not q.dead and q.shell == shell then live = live + 1 end end
    p.stack = live
    M.popups[#M.popups + 1] = p
    while #M.popups > M.popupSettings.max do
        local old = table.remove(M.popups, 1)
        if old and not old.dead then pcall(function() old:kill() end) end
    end
    return p
end

function M.popupTick()
    local keep = {}
    for _, p in ipairs(M.popups) do if not p.dead then keep[#keep + 1] = p end end
    M.popups = keep
end

return M
