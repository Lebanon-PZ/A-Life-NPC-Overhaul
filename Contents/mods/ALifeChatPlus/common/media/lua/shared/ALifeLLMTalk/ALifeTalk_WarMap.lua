-- A-Life NPC Overhaul 0.7.0: THE WAR MAP. What you know about who's fighting whom, drawn on your map.
-- Only KNOWN wars: you hear of a war from traders who visit, from groups who answer your radio, from people passing
-- on rumours, or because you were close enough to hear the shooting. Each war you know shows who, since when you've
-- known, the last you heard, who seemed to be winning (from the fights you heard about), and where it came from.
-- Territory is an estimate: a soft circle around where you think a group lives, its size from how many you were told
-- they are (plus outposts you know of). Rough knowledge = a blurrier, bigger circle. Old news fades.
-- Nothing on the war map is live: a war you haven't heard about isn't there, and one that ended still shows until
-- someone tells you it's over.
-- Open it from the Journal ("War map"), or toggle it with the button on the world map.
-- Performance: nothing runs unless the map is open with the war map on; then the drawing list is rebuilt every 2 s.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("ui", "ALifeTalk_WarMap") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
local M = ALifeLLMTalk
if type(M) ~= "table" then return end
M.wmCfg = M.wmCfg or { endDays = 30, seenTiles = 200, tellTiles = 900, keepRaids = 8,
    rel = { seen = 0.9, traders = 0.8, fighters = 0.8, radio = 0.7, rumor = 0.5 }, halfLifeDays = 10,
    baseR = 60, perMember = 14, roughR = 1.6, rebuildMs = 2000 }
M.wmStats = M.wmStats or { fights = 0, learned = 0, draws = 0 }
if M.settings and M.settings.warMap == nil then M.settings.warMap = true end

local function log(msg) if M.log then M.log("warmap: " .. tostring(msg)) end end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
local function now() return type(getTimestampMs) == "function" and getTimestampMs() or 0 end
local function d2(ax, ay, bx, by) return (ax - bx) ^ 2 + (ay - by) ^ 2 end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function hash(s) local h = 5381; s = tostring(s); for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end; return h end
local function tr(k, en, ...)
    if ALifeTr then return ALifeTr("IGUI_ALCP_" .. k, en, ...) end
    local args = { ... }
    return (string.gsub(en, "{(%d)}", function(i) return tostring(args[tonumber(i)] or "") end))
end
local function store()
    local st = M.nbStore()
    st.wmTruth = type(st.wmTruth) == "table" and st.wmTruth or {}
    st.wmKnown = type(st.wmKnown) == "table" and st.wmKnown or {}
    return st
end
local function keyOf(a, b) local x, y = tostring(a), tostring(b); if x < y then return x .. "|" .. y end return y .. "|" .. x end
local function byId(id) local st = M.nbStore(); return st.byId and st.byId[id] or nil end
local function ago(h0) if fn(M, "jnAgo") then return M.jnAgo(h0) end return math.floor((hours() - (tonumber(h0) or 0)) / 24) .. " days ago" end

----------------------------------------------------------------------------------------------------------------
-- what really happened (the world keeps score; you only see what you're told)
----------------------------------------------------------------------------------------------------------------
-- a fight between groups: by = attacker, on = target, won = the attacker got what they came for
function M.wmRecord(by, on, h, won)
    if type(by) ~= "table" or type(on) ~= "table" or by.id == on.id then return end
    local st = store()
    local k = keyOf(by.id, on.id)
    local w = st.wmTruth[k]
    if w == nil then w = { a = tostring(by.id), b = tostring(on.id), first = h, raids = {} }; st.wmTruth[k] = w end
    w.last = h
    w.raids[#w.raids + 1] = { h = h, by = tostring(by.id), won = won == true }
    while #w.raids > M.wmCfg.keepRaids do table.remove(w.raids, 1) end
    M.wmStats.fights = M.wmStats.fights + 1
    -- close enough to hear it: you know
    local px, py = nil, nil
    pcall(function() local p = ALifeSide.you(); px, py = p:getX(), p:getY() end)
    if px and tonumber(on.x) and d2(px, py, on.x, on.y) <= M.wmCfg.seenTiles ^ 2 then
        M.wmLearn(k, "seen", nil, h, "You heard shooting from " .. tostring(on.name) .. "'s place")
    end
end
-- is it still a war? (fighting in the last endDays, or they still call each other enemies)
function M.wmLive(w, h)
    if type(w) ~= "table" then return false end
    if h - (tonumber(w.last) or -1e9) <= M.wmCfg.endDays * 24 then return true end
    local a, b = byId(w.a), byId(w.b)
    if not (a and b and a.status == "active" and b.status == "active") then return false end
    local tie = fn(M, "dirTie") and M.dirTie(a, b) or 0
    return tie <= -40
end

----------------------------------------------------------------------------------------------------------------
-- what you know
----------------------------------------------------------------------------------------------------------------
-- you learn about war k (from src, told by someone named by): you know what had happened up to now
function M.wmLearn(k, src, by, h, text)
    local st = store()
    local w = st.wmTruth[k]
    if w == nil then return false end
    local kn = st.wmKnown[k]
    local fresh = kn == nil
    if kn == nil then kn = { a = w.a, b = w.b, firstHeard = h }; st.wmKnown[k] = kn end
    local rel = M.wmCfg.rel[src] or 0.5
    -- a newer or more reliable account replaces what you had
    if (tonumber(kn.at) or -1e9) < h - 1 or rel >= (tonumber(kn.rel) or 0) then
        kn.at, kn.src, kn.by, kn.rel = h, src, by, rel
        kn.live = M.wmLive(w, h)
        kn.since = w.first
        kn.lastFight = w.last
        local aw, bw = 0, 0
        for _, r in ipairs(w.raids) do
            local att = r.by == w.a
            if r.won == att then aw = aw + 1 else bw = bw + 1 end
        end
        kn.aWins, kn.bWins, kn.fights = aw, bw, #w.raids
        kn.note = text
    end
    if fresh then M.wmStats.learned = M.wmStats.learned + 1 end
    return fresh
end
-- someone from group b tells you about wars: their own (they know them well) and their neighbours' (rumour)
function M.wmTell(b, h, via)
    if M.settings.warMap == false or type(b) ~= "table" or not tonumber(b.x) then return 0 end
    local st = store()
    local n = 0
    for k, w in pairs(st.wmTruth) do
        local mine = w.a == tostring(b.id) or w.b == tostring(b.id)
        local near = false
        if not mine then
            local a, c = byId(w.a), byId(w.b)
            near = (a and tonumber(a.x) and d2(a.x, a.y, b.x, b.y) <= M.wmCfg.tellTiles ^ 2) or (c and tonumber(c.x) and d2(c.x, c.y, b.x, b.y) <= M.wmCfg.tellTiles ^ 2) or false
        end
        if (mine or near) and M.wmLive(w, h) then
            local other = byId(mine and (w.a == tostring(b.id) and w.b or w.a) or w.b)
            local text = mine and (tostring(b.name) .. " say they're at war with " .. tostring(other and other.name or "someone"))
                or (tostring(b.name) .. " say " .. tostring((byId(w.a) or {}).name) .. " and " .. tostring((byId(w.b) or {}).name) .. " are at war")
            local src = mine and (via == "radio" and "radio" or "traders") or "rumor"
            local kn = st.wmKnown[k]
            if not (kn and h - (tonumber(kn.at) or -1e9) < 24 and (tonumber(kn.rel) or 0) >= (M.wmCfg.rel[src] or 0)) then
                M.wmLearn(k, src, b.name, h, text)
                n = n + 1
            end
        end
    end
    -- a war they say is over: you learn that too
    for k, kn in pairs(st.wmKnown) do
        if kn.live and (kn.a == tostring(b.id) or kn.b == tostring(b.id)) and not M.wmLive(st.wmTruth[k], h) then
            kn.live, kn.at, kn.src, kn.by = false, h, via == "radio" and "radio" or "traders", b.name
            kn.note = tostring(b.name) .. " say the fighting is over"
            n = n + 1
        end
    end
    return n
end

-- how much to trust what you know about war k now: the source's reliability, fading with age
function M.wmTrust(kn, h)
    local age = math.max(0, h - (tonumber(kn.at) or h)) / 24
    return (tonumber(kn.rel) or 0.5) * (0.5 ^ (age / M.wmCfg.halfLifeDays))
end
function M.wmTrustWord(t)
    if t >= 0.7 then return tr("WarTrustGood", "good information") elseif t >= 0.45 then return tr("WarTrustFair", "fair information")
    elseif t >= 0.25 then return tr("WarTrustThin", "thin information") end
    return tr("WarTrustOld", "old news")
end
-- who seems to be winning (from the fights you heard about)
function M.wmLeanWord(kn)
    local a, b = byId(kn.a), byId(kn.b)
    local aw, bw = tonumber(kn.aWins) or 0, tonumber(kn.bWins) or 0
    if aw + bw == 0 then return tr("WarLeanNone", "no word on who's winning") end
    if aw >= bw + 2 then return tr("WarLeanA", "{1} seem to be winning", tostring(a and a.name or "?")) end
    if bw >= aw + 2 then return tr("WarLeanA", "{1} seem to be winning", tostring(b and b.name or "?")) end
    return tr("WarLeanEven", "neither side is winning")
end

-- the known wars, newest news first: rows for the journal
function M.wmRows(h)
    h = h or hours()
    local rows = {}
    for k, kn in pairs(store().wmKnown) do
        local a, b = byId(kn.a), byId(kn.b)
        rows[#rows + 1] = { key = k, a = a, b = b, kn = kn, live = kn.live ~= false, trust = M.wmTrust(kn, h),
            text = tostring(a and a.name or "?") .. " vs " .. tostring(b and b.name or "?") }
    end
    table.sort(rows, function(x, y) if x.live ~= y.live then return x.live end return (tonumber(x.kn.at) or 0) > (tonumber(y.kn.at) or 0) end)
    return rows
end
function M.wmText(h)
    h = h or hours()
    local lines = {}
    for _, r in ipairs(M.wmRows(h)) do
        local kn = r.kn
        lines[#lines + 1] = (r.live and "" or "(over) ") .. r.text .. ": " .. M.wmLeanWord(kn) .. ". Heard " .. ago(kn.at)
            .. (kn.by and (" from " .. tostring(kn.by)) or "") .. " (" .. tostring(kn.src) .. ", " .. M.wmTrustWord(r.trust) .. ")."
            .. (kn.note and (" " .. tostring(kn.note) .. ".") or "")
    end
    if #lines == 0 then return tr("WarNone", "You haven't heard of any wars. Traders, the radio and the sound of shooting tell you about them.") end
    return table.concat(lines, " <LINE> <LINE> ")
end

----------------------------------------------------------------------------------------------------------------
-- estimated territory: what you think, from what you know (never the live position)
----------------------------------------------------------------------------------------------------------------
local function colorOf(id)
    local h = hash(id) % 360 / 60
    local i = math.floor(h)
    local f = h - i
    local c = { { 1, f, 0 }, { 1 - f, 1, 0 }, { 0, 1, f }, { 0, 1 - f, 1 }, { f, 0, 1 }, { 1, 0, 1 - f } }
    local r = c[i + 1] or { 1, 1, 1 }
    return 0.35 + r[1] * 0.6, 0.35 + r[2] * 0.6, 0.35 + r[3] * 0.6
end
function M.wmTerritory(b, h)
    if type(b) ~= "table" or type(b.intel) ~= "table" then return nil end
    local i = b.intel
    local x, y = tonumber(i.x), tonumber(i.y)
    if x == nil then return nil end
    local members = tonumber(i.members) or 6
    local r = M.wmCfg.baseR + M.wmCfg.perMember * math.sqrt(math.max(1, members))
    if not i.exact then r = r * M.wmCfg.roughR end
    local age = math.max(0, h - (tonumber(i.at) or h)) / 24
    local cr, cg, cb = colorOf(b.parentId or b.outpostOf or b.id)
    return { id = b.id, name = b.name, x = x, y = y, r = r, exact = i.exact == true, fade = 0.5 ^ (age / M.wmCfg.halfLifeDays),
        cr = cr, cg = cg, cb = cb, outpost = b.outpostOf ~= nil, choke = i.choke }
end
-- everything to draw: territories of groups in known wars (and outposts of theirs you know), and the war lines
function M.wmDrawList(h)
    h = h or hours()
    local list = { areas = {}, lines = {} }
    local seen = {}
    local function add(b)
        if b == nil or seen[b.id] then return seen[b and b.id] end
        local t = M.wmTerritory(b, h)
        seen[b.id] = t or false
        if t then list.areas[#list.areas + 1] = t end
        return t
    end
    for _, r in ipairs(M.wmRows(h)) do
        local ta, tb = add(r.a), add(r.b)
        if r.live and ta and tb then
            list.lines[#list.lines + 1] = { ax = ta.x, ay = ta.y, bx = tb.x, by = tb.y, label = r.text, trust = r.trust }
        end
    end
    -- outposts of the groups shown (that you know about)
    local st = M.nbStore()
    for _, o in pairs(st.byId or {}) do
        if type(o) == "table" and o.status == "active" and o.outpostOf and seen[o.outpostOf] then add(o) end
    end
    M.wmStats.draws = M.wmStats.draws + 1
    return list
end

----------------------------------------------------------------------------------------------------------------
-- drawing on the world map
----------------------------------------------------------------------------------------------------------------
M.wmOn = M.wmOn or false
local disc = nil
local function tex()
    if disc == nil then pcall(function() disc = getTexture("media/ui/ALifeTalk/war_disc.png") end); if disc == nil then disc = false end end
    return disc or nil
end
function M.wmRender(map)
    if not M.wmOn or M.settings.warMap == false then return end
    local api = map and map.mapAPI
    if api == nil then return end
    local t = now()
    if M._wmList == nil or t - (M._wmListAt or 0) > M.wmCfg.rebuildMs then M._wmList, M._wmListAt = M.wmDrawList(hours()), t end
    local L = M._wmList
    local d = tex()
    local function ux(x, y) return api:worldToUIX(x, y) end
    local function uy(x, y) return api:worldToUIY(x, y) end
    for _, a in ipairs(L.areas) do
        local cx, cy = ux(a.x, a.y), uy(a.x, a.y)
        local ex = ux(a.x + a.r, a.y)
        local rr = math.abs(ex - cx)
        local alpha = (a.exact and 0.45 or 0.3) * math.max(0.25, a.fade)
        if d and rr > 2 then map:drawTextureScaled(d, cx - rr, cy - rr, rr * 2, rr * 2, alpha, a.cr, a.cg, a.cb) end
        local label = tostring(a.name) .. (a.outpost and (a.choke and (" (" .. tostring(a.choke) .. ")") or " (outpost)") or "")
        map:drawTextCentre(label, cx, cy - 7, a.cr, a.cg, a.cb, math.max(0.5, a.fade), UIFont.Small)
    end
    for _, l in ipairs(L.lines) do
        local x1, y1, x2, y2 = ux(l.ax, l.ay), uy(l.ax, l.ay), ux(l.bx, l.by), uy(l.bx, l.by)
        local len = math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2)
        local n = math.min(200, math.floor(len / 9))
        local alpha = 0.35 + 0.6 * math.min(1, l.trust / 0.8)
        for i = 1, n - 1 do
            local f = i / n
            map:drawRect(x1 + (x2 - x1) * f - 1.5, y1 + (y2 - y1) * f - 1.5, 3, 3, alpha, 0.9, 0.15, 0.1)
        end
        map:drawTextCentre(tr("WarAtWar", "at war"), (x1 + x2) / 2, (y1 + y2) / 2 - 14, 0.95, 0.3, 0.25, alpha, UIFont.Small)
    end
end
function M.wmOpen(on)
    M.wmOn = on ~= false
    M._wmList = nil
    pcall(function() ISWorldMap.ShowWorldMap(0) end)
end

local broken = false
function M.wmInstall()
    if ISWorldMap == nil or ISWorldMap._alcpWar then return ISWorldMap ~= nil end
    ISWorldMap._alcpWar = true
    local render = ISWorldMap.render
    ISWorldMap.render = function(self, ...)
        local r = render(self, ...)
        if M.wmOn and not broken then
            local ok, err = pcall(M.wmRender, self)
            if not ok then broken = true; print("[ALifeWarMap] drawing failed, war map off for this session: " .. tostring(err)) end
        end
        return r
    end
    local create = ISWorldMap.createChildren
    ISWorldMap.createChildren = function(self, ...)
        local r = create(self, ...)
        pcall(function()
            if M.settings.warMap == false then return end
            local label = tr("WarMapButton", "War map")
            local w = getTextManager():MeasureStringX(UIFont.Small, label) + 20
            local b = ISButton:new(self.width - w - 12, 48, w, 22, label, self, function() M.wmOn = not M.wmOn; M._wmList = nil end)
            b:initialise(); b:instantiate()
            if type(AA_Tip) == "table" then AA_Tip.own(b, AA_Tip.lookup("War map")) end -- pre-1.0: hover tip
            self:addChild(b)
            self.alcpWarButton = b
        end)
        return r
    end
    return true
end

-- the journal: a "Wars" list and a "War map" button
function M.wmInstallJournal()
    local PW = ALifeTalkPlacesWindow
    if type(PW) ~= "table" or PW._alcpWar then return false end
    PW._alcpWar = true
    local create = PW.createChildren
    PW.createChildren = function(self, ...)
        local r = create(self, ...)
        pcall(function()
            if M.settings.warMap == false then return end
            local by = self.height - 66
            local x = self.width - 12
            for _, c in ipairs({ { tr("WarMapButton", "War map"), function() M.wmOpen(true) end }, { tr("WarListButton", "Wars"), function()
                    local modal = ISModalRichText:new(getCore():getScreenWidth() / 2 - 300, getCore():getScreenHeight() / 2 - 200, 600, 400,
                        tr("WarListTitle", "Wars you know of") .. " <LINE> <LINE> " .. M.wmText(), false)
                    modal:initialise(); modal:addToUIManager()
                end } }) do
                local w = getTextManager():MeasureStringX(UIFont.Small, c[1]) + 20
                x = x - w
                local b = ISButton:new(x, by, w, 24, c[1], self, c[2])
                b:initialise(); b:instantiate(); self:addChild(b)
                x = x - 6
            end
        end)
        return r
    end
    return true
end

local function hooks()
    pcall(M.wmInstall)
    pcall(M.wmInstallJournal)
    if not M._wmArrive then
        M._wmArrive = true
        M.cvArriveHooks = M.cvArriveHooks or {}
        table.insert(M.cvArriveHooks, function(visit, b, h) pcall(M.wmTell, b, h, "traders") end)
    end
end
if Events and Events.OnGameStart then Events.OnGameStart.Add(hooks) end
hooks()
print("[ALifeWarMap] loaded v" .. ALifeSide.MOD_VERSION .. " (known wars and estimated territory on your map)")
