-- A-Life Talk 0.5.2.10 [pt270u]: THE WEB TAB. "for their relationships in the tab, would be cool if we had a tab in the
-- shape of like a web" + "in the middle where josh can be can we show his full body".
-- After "Close with": the person in the middle - their full-body model (the window's own ISUI3DModel, MOVED into a
-- tall card while this tab is open and put back after: no second 3D model), else the stand-in silhouette - with the
-- name and status pills (BITTEN, mood) under it. Spokes from the card's edge to every tie on an ellipse (strongest
-- at the top, at most 11 + You, "+N more"; a second ring when name pills would overlap): partner pink, friend / buddy
-- blue, family green, crush light pink, rival / nemesis / enemy red, the dead grey and dashed (name dimmed, a cross),
-- you gold with the bond tier; thickness from the strength; the tie word as a small pill mid-line. Faint chords
-- between people on the web who are tied to each other. Hover a name: their tie and opinions; click: their own
-- Relationship window (only people you know).
-- PZ's UI has no line primitive: a line is a list of small rects (one per step of its thickness along the short
-- axis; dashes skip every other piece). All geometry (nodes, rects, pills) is built ONCE per tab open / data change /
-- resize into self.web, prerender only walks the lists (no maths per frame). Setting: uiWeb.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("ui", "ALifeLLMTalk_UIWeb") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "UIWeb"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("UIWeb") end end
local M = ALifeLLMTalk
if type(M) ~= "table" then return end
local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, name) return type(t) == "table" and type(t[name]) == "function" end
local function firstOf(name) return string.match(tostring(name), "^(%S+)") or tostring(name) end

M.webCfg = { maxNodes = 11, ring2 = 0.7, chords = true, pad = 8 }
M.webColors = {
    partner = { r = 0.92, g = 0.48, b = 0.68 }, crush = { r = 0.95, g = 0.7, b = 0.82 }, admirer = { r = 0.95, g = 0.7, b = 0.82 },
    friend = { r = 0.45, g = 0.75, b = 0.92 }, family = { r = 0.45, g = 0.78, b = 0.5 }, you = { r = 0.9, g = 0.72, b = 0.3 },
    hostile = { r = 0.88, g = 0.3, b = 0.26 }, dead = { r = 0.5, g = 0.5, b = 0.52 }, other = { r = 0.62, g = 0.64, b = 0.68 },
    bite = { r = 0.9, g = 0.25, b = 0.22 } }
local FAMILY = { sibling = true, parent = true, child = true }
local FRIEND = { ["best friend"] = true, buddy = true, friend = true, ally = true, comrade = true, respect = true }
local HOSTILE = { rival = true, nemesis = true, enemy = true, distrust = true, ex = true }
function M.webColor(t, dead, isYou)
    local C = M.webColors
    if isYou then return C.you end
    if dead then return C.dead end
    if t == "partner" then return C.partner end
    if t == "crush" or t == "admirer" then return C.crush end
    if FAMILY[t] then return C.family end
    if FRIEND[t] then return C.friend end
    if HOSTILE[t] then return C.hostile end
    return C.other
end
local TYPE_RANK = { partner = 1, parent = 2, child = 2, sibling = 2, ["best friend"] = 3, nemesis = 3, crush = 4, admirer = 4, rival = 4,
    buddy = 5, friend = 5, enemy = 5, ex = 6, distrust = 6, comrade = 7, respect = 7, ally = 8 }

----------------------------------------------------------------------------------------------------------------
-- geometry (pure; tested): a line as rects, the ray / box edge, the node layout
----------------------------------------------------------------------------------------------------------------
-- rects { x, y, w, h } for a line of thickness t; dash = piece length (nil = solid)
function M.webLineRects(x0, y0, x1, y1, t, dash)
    t = math.max(1, math.floor((tonumber(t) or 1) + 0.5))
    local out = {}
    local dx, dy = x1 - x0, y1 - y0
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 1 then return out end
    local function solid(ax, ay, bx, by)
        local ddx, ddy = bx - ax, by - ay
        if math.abs(ddx) >= math.abs(ddy) then
            local n = math.max(1, math.ceil(math.abs(ddy) / t))
            for i = 0, n - 1 do
                local xa, xb = ax + ddx * i / n, ax + ddx * (i + 1) / n
                local yy = ay + ddy * (i + 0.5) / n
                local lx = math.min(xa, xb)
                out[#out + 1] = { math.floor(lx), math.floor(yy - t / 2), math.max(1, math.ceil(math.abs(xb - xa)) + 1), t }
            end
        else
            local n = math.max(1, math.ceil(math.abs(ddx) / t))
            for i = 0, n - 1 do
                local ya, yb = ay + ddy * i / n, ay + ddy * (i + 1) / n
                local xx = ax + ddx * (i + 0.5) / n
                local ly = math.min(ya, yb)
                out[#out + 1] = { math.floor(xx - t / 2), math.floor(ly), t, math.max(1, math.ceil(math.abs(yb - ya)) + 1) }
            end
        end
    end
    if dash == nil then solid(x0, y0, x1, y1); return out end
    local pieces = math.max(1, math.floor(len / dash))
    for i = 0, pieces - 1, 2 do
        local a, b = i / pieces, math.min(1, (i + 1) / pieces)
        solid(x0 + dx * a, y0 + dy * a, x0 + dx * b, y0 + dy * b)
    end
    return out
end

-- where the ray from a box's centre toward (tx, ty) leaves the box (half sizes hw, hh)
function M.webBoxEdge(cx, cy, hw, hh, tx, ty)
    local dx, dy = tx - cx, ty - cy
    if dx == 0 and dy == 0 then return cx, cy end
    local k = math.min(dx ~= 0 and (hw / math.abs(dx)) or 1e9, dy ~= 0 and (hh / math.abs(dy)) or 1e9)
    k = math.min(1, k)
    return cx + dx * k, cy + dy * k
end

local function overlap(a, b, pad)
    return a.x < b.x + b.w + pad and b.x < a.x + a.w + pad and a.y < b.y + b.h + pad and b.y < a.y + a.h + pad
end

-- nodes = { { w, h }, ... } sorted strongest first; area = { x, y, w, h }; card = { w, h } in the middle
-- -> each node gets x, y (top-left), cx, cy, ring; returns rx, ry
function M.webLayout(nodes, area, card)
    local n = #nodes
    local cx, cy = area.x + area.w / 2, area.y + area.h / 2
    local maxW, maxH = 40, 16
    for _, nd in ipairs(nodes) do maxW = math.max(maxW, nd.w); maxH = math.max(maxH, nd.h) end
    -- an ellipse wide enough that the tall card in the middle never touches a node
    local rx = math.max(card.w / 2 + maxW / 2 + 40, area.w / 2 - maxW / 2 - 6)
    local ry = math.max(card.h / 2 * 0.55, area.h / 2 - maxH / 2 - 6)
    local function place(nd, ang, k)
        nd.cx, nd.cy = cx + math.cos(ang) * rx * k, cy + math.sin(ang) * ry * k
        nd.x, nd.y = math.floor(nd.cx - nd.w / 2), math.floor(nd.cy - nd.h / 2)
        nd.ang, nd.ring = ang, (k < 1) and 2 or 1
    end
    local cardBox = { x = cx - card.w / 2, y = cy - card.h / 2, w = card.w, h = card.h }
    for i, nd in ipairs(nodes) do
        -- strongest on top; with one or two people they sit left / right (the room is sideways, the card is tall)
        local ang = (n <= 2 and math.pi or -math.pi / 2) + (i - 1) * 2 * math.pi / math.max(1, n)
        place(nd, ang, 1)
    end
    -- second ring: a node that overlaps its neighbour moves inward (if that stays clear of the card), else outward a bit
    for i = 2, n do
        local nd = nodes[i]
        local hit = overlap(nd, nodes[i - 1], 4) or (i == n and n > 2 and overlap(nd, nodes[1], 4))
        if hit then
            place(nd, nd.ang, M.webCfg.ring2)
            if overlap(nd, cardBox, 6) or overlap(nd, nodes[i - 1], 2) then place(nd, nd.ang, 1); nd.y = nd.y + nd.h + 4; nd.cy = nd.cy + nd.h + 4; nd.ring = 2 end
        end
    end
    -- keep every node inside the area
    for _, nd in ipairs(nodes) do
        local nx = math.max(area.x, math.min(nd.x, area.x + area.w - nd.w))
        local ny = math.max(area.y, math.min(nd.y, area.y + area.h - nd.h))
        nd.cx, nd.cy = nd.cx + (nx - nd.x), nd.cy + (ny - nd.y)
        nd.x, nd.y = nx, ny
    end
    return rx, ry, cardBox
end

----------------------------------------------------------------------------------------------------------------
-- data: the web of one person (ties + you), capped
----------------------------------------------------------------------------------------------------------------
function M.webData(uid, player)
    uid = tostring(uid)
    local list = {}
    if M.tiesOf then
        local ok, ties = pcall(M.tiesOf, uid, player, nil, false)
        if ok and type(ties) == "table" then list = ties end
    end
    local nodes = {}
    for _, t in ipairs(list) do
        nodes[#nodes + 1] = { uid = tostring(t.uid), name = tostring(t.name), type = t.type, word = tostring(t.word or t.type), score = tonumber(t.score) or 0,
            dead = t.dead == true, known = t.known ~= false }
    end
    table.sort(nodes, function(a, b)
        local ra, rb = TYPE_RANK[a.type] or 9, TYPE_RANK[b.type] or 9
        if a.dead ~= b.dead then return not a.dead end
        if ra ~= rb then return ra < rb end
        if math.abs(a.score) ~= math.abs(b.score) then return math.abs(a.score) > math.abs(b.score) end
        return a.uid < b.uid
    end)
    -- the player: their bond tier (else the tie word); the strongest link goes to the top
    local you = nil
    if player ~= nil then
        local v = 0
        pcall(function() local r = PA().ActorRegistry.read(uid); v = (M.opinionView and M.opinionView(r, player)) or 0 end)
        local word = nil
        if M.settings.bondTiers ~= false and M.bondTier and M.tierWord then pcall(function() word = M.tierWord(M.bondTier(uid)) end) end
        if word == nil and M.playerTie then pcall(function() word = M.playerTie(PA().ActorRegistry.read(uid), player) end) end
        you = { uid = "player", name = "You", type = "you", word = tostring(word or "met"), score = tonumber(v) or 0, you = true, known = false }
    end
    local more = 0
    while #nodes > M.webCfg.maxNodes do table.remove(nodes); more = more + 1 end
    if you then
        local at = #nodes + 1
        for i, nd in ipairs(nodes) do
            if nd.dead or (math.abs(you.score) >= math.abs(nd.score) and (TYPE_RANK[nd.type] or 9) > 2) then at = i; break end -- the living first
        end
        table.insert(nodes, at, you)
    end
    for _, nd in ipairs(nodes) do
        if not nd.you and not nd.dead and M.biteInfo then local ok, bi = pcall(M.biteInfo, nd.uid); nd.bitten = ok and bi ~= nil end
    end
    return nodes, more
end

----------------------------------------------------------------------------------------------------------------
-- the window: tab, build (cached), draw, hover, click, the model in the middle
----------------------------------------------------------------------------------------------------------------
function M.webUIInstall()
    local W = ALifeTalkRelationWindow
    if W == nil or W._webUI or M.settings.uiWeb == false then return end
    local T, S = M.Theme, M.UIStyle
    if T == nil or S == nil or W.TAB == nil or W.TAB.close == nil then return end
    W._webUI = true
    local at = W.TAB.close + 1
    table.insert(W.TABS, at, "Web")
    for k, v in pairs(W.TAB) do if v >= at then W.TAB[k] = v + 1 end end
    W.TAB.web = at
    local F = M.Fancy

    local function pill(ui, x, y, text, c, a)
        if F and F.pill then return F.pill(ui, x, y, text, c, a) end
        return T.badge(ui, x, y, text, c, a)
    end
    local function pillW(text) if F and F.pillW then return F.pillW(text) end return T.textW(text) + 16 end

    -- the model: moved into the card while the Web tab is open, back to the portrait frame after
    function W:webModel(on)
        local m = self.model
        if m == nil then return end
        pcall(function()
            if on and self.web and self.web.card then
                local c = self.web.card
                m:setX(c.mx); m:setY(c.my); m:setWidth(c.mw); m:setHeight(c.mh)
                self.webModelIn, self.webModelRef = true, m
            elseif self.webModelIn then
                m:setX(self.portraitX); m:setY(self.portraitY); m:setWidth(self.portraitW); m:setHeight(self.portraitH)
                self.webModelIn = false
            end
        end)
    end

    function W:webSig()
        local d = self.data or {}
        local parts = { tostring(self.width), tostring(self.height), tostring(T.fontH()), tostring(d.value), tostring(d.bite ~= nil) }
        for _, t in ipairs(d.ties or {}) do parts[#parts + 1] = tostring(t.uid) .. ":" .. tostring(t.type) .. ":" .. tostring(t.score) .. ":" .. tostring(t.dead) end
        return table.concat(parts, "|")
    end

    function W:webBuild()
        local L = self.lay or (self.fitLayout and self:fitLayout(true)) or {}
        local d = self.data or {}
        local fh = T.fontH()
        local x0 = self.cx or 176
        local top = (L.y0 or (self:contentTop() + 124)) + fh + 8 -- under the "JOSH'S PEOPLE" header
        local hintY = self.height - (L.bottom or 46) - fh - 4
        -- the legend: one or two rows above the hint line (never over a node, never past the edge)
        local legend, lx, rowsN = {}, x0 + 4, 1
        local rightX = self.width - 14
        for _, row in ipairs({ { "partner", M.webColors.partner }, { "friend / buddy", M.webColors.friend }, { "family", M.webColors.family },
            { "you", M.webColors.you }, { "rival / nemesis", M.webColors.hostile }, { "deceased", M.webColors.dead } }) do
            local w = 22 + T.textW(row[1]) + 14
            if lx + w > rightX and lx > x0 + 4 then lx = x0 + 4; rowsN = rowsN + 1 end
            legend[#legend + 1] = { x = lx, row = rowsN, text = row[1], c = row[2] }
            lx = lx + w
        end
        local legendY = hintY - rowsN * (fh + 2) - 4
        for _, lg in ipairs(legend) do lg.y = legendY + (lg.row - 1) * (fh + 2) end
        local bottom = legendY - 6
        local area = { x = x0 + 4, y = top, w = self.width - x0 - 20, h = math.max(120, bottom - top) }
        local nodes, more = M.webData(self.uid, ALifeSide.you())
        local ph = fh + 4
        for _, nd in ipairs(nodes) do
            nd.label = T.fit(nd.name, 150)
            nd.w, nd.h = pillW(nd.label) + (nd.dead and 14 or 0), ph
        end
        -- the card: tall (full body), name + status pills under the model
        -- leave room above and below the card for a node + its spoke label (the top / bottom spokes were stubs)
        local cardH = math.floor(math.max(110, math.min(area.h * 0.78, area.h - 4 * ph - 24, 300)))
        local pillsH = 2 * ph + 10
        local modelH = math.max(60, cardH - pillsH - 10)
        local modelW = math.floor(modelH * 0.55)
        local cardW = math.max(modelW + 16, pillW(firstOf(d.name or "")) + 16, pillW("BITTEN") + 16)
        local rx, ry, box = M.webLayout(nodes, area, { w = cardW, h = cardH })
        local ccx, ccy = box.x + cardW / 2, box.y + cardH / 2
        local web = { nodes = nodes, more = more, area = area, lines = {}, chords = {}, labels = {}, built = (self.webBuilt or 0) + 1,
            legend = legend, hintY = hintY,
            hint = T.fit("Hover a name for opinions  -  click: what they said to each other  -  faint lines = they know each other", self.width - x0 - 20) }
        web.card = { x = math.floor(box.x), y = math.floor(box.y), w = cardW, h = cardH, mx = math.floor(ccx - modelW / 2), my = math.floor(box.y + 6),
            mw = modelW, mh = modelH, name = firstOf(d.name or "?"), nameY = math.floor(box.y + 8 + modelH), pillY = math.floor(box.y + 10 + modelH + ph) }
        web.card.pills = {}
        if d.bite and not d.dead then web.card.pills[#web.card.pills + 1] = { "BITTEN", M.webColors.bite } end
        if d.mood and not d.dead then web.card.pills[#web.card.pills + 1] = { tostring(d.mood), S.blue } end
        if d.dead then web.card.pills[#web.card.pills + 1] = { "DEAD", M.webColors.dead } end
        -- spokes: card edge -> node edge; the tie word mid-line
        for _, nd in ipairs(nodes) do
            local c = M.webColor(nd.type, nd.dead, nd.you)
            local sx, sy = M.webBoxEdge(ccx, ccy, cardW / 2, cardH / 2, nd.cx, nd.cy)
            local ex, ey = M.webBoxEdge(nd.cx, nd.cy, nd.w / 2, nd.h / 2, ccx, ccy)
            local thick = 1 + math.floor(math.min(100, math.abs(nd.score)) / 40)
            if nd.type == "partner" or nd.you then thick = math.max(2, thick) end
            web.lines[#web.lines + 1] = { rects = M.webLineRects(sx, sy, ex, ey, thick, nd.dead and 6 or nil), c = c, a = nd.dead and 0.55 or 0.9 }
            local word = (nd.dead and M.lateTypes and M.lateTypes[nd.type] and string.sub(nd.word, 1, 5) ~= "late ") and ("late " .. nd.word) or nd.word
            word = T.fit(word, 110)
            local lw = pillW(word)
            web.labels[#web.labels + 1] = { x = math.floor((sx + ex) / 2 - lw / 2), y = math.floor((sy + ey) / 2 - ph / 2), text = word, c = c, a = nd.dead and 0.6 or 1 }
            nd.c = c
        end
        -- chords: people on the web tied to each other (faint)
        if M.webCfg.chords and M.pairRow then
            for i = 1, #nodes do
                for j = i + 1, #nodes do
                    local a, b = nodes[i], nodes[j]
                    if not a.you and not b.you then
                        local row = M.pairRow(a.uid, b.uid, false)
                        if row and row.t ~= "stranger" and row.t ~= "acquaintance" then
                            web.chords[#web.chords + 1] = { rects = M.webLineRects(a.cx, a.cy, b.cx, b.cy, 1, 5), c = M.webColor(row.t, false, false), a = 0.28 }
                        end
                    end
                end
            end
        end
        self.web, self.webBuilt, self.webKey = web, web.built, self:webSig()
        if self.activeTab == W.TAB.web then self:webModel(true) end
        return web
    end

    function W:webDraw()
        local web = self.web
        if web == nil then return end
        local a = self.fade or 1
        local fh = T.fontH()
        local d = self.data or {}
        local G = (F and F.C and F.C.gold) or S.accent
        local L = self.lay or {}
        local x0 = self.cx or 176
        local hy = (L.y0 or (self:contentTop() + 124))
        self:drawText(string.upper(firstOf(d.name or "") .. "'s people"), x0 + 4, hy, G.r, G.g, G.b, a, S.font)
        for _, lg in ipairs(web.legend or {}) do
            self:drawRect(lg.x, lg.y + math.floor(fh / 2), 16, 2, a, lg.c.r, lg.c.g, lg.c.b)
            self:drawText(lg.text, lg.x + 22, lg.y, S.dim.r, S.dim.g, S.dim.b, a, S.font)
        end
        for _, ln in ipairs(web.chords) do
            for _, r in ipairs(ln.rects) do self:drawRect(r[1], r[2], r[3], r[4], a * ln.a, ln.c.r, ln.c.g, ln.c.b) end
        end
        for _, ln in ipairs(web.lines) do
            for _, r in ipairs(ln.rects) do self:drawRect(r[1], r[2], r[3], r[4], a * ln.a, ln.c.r, ln.c.g, ln.c.b) end
        end
        for _, lb in ipairs(web.labels) do pill(self, lb.x, lb.y, lb.text, lb.c, a * lb.a) end
        -- the card in the middle (the model is a child: it draws on top of this)
        local c = web.card
        if F and F.rrect then
            F.rrect(self, c.x, c.y, c.w, c.h, 6, G, a)
            F.rrect(self, c.x + 1, c.y + 1, c.w - 2, c.h - 2, 5, { r = 0.13, g = 0.12, b = 0.1 }, a)
        else T.box(self, c.x, c.y, c.w, c.h, S.panel, S.border or S.borderDim, a) end
        if not (self.model ~= nil and self.webModelIn and (self.portraitMode == "live" or self.portraitMode == "standin" or self.portraitMode == nil)) then
            local mx, mw, my, mh = c.mx, c.mw, c.my, c.mh -- stand-in silhouette (no model)
            local col = { r = 0.3, g = 0.3, b = 0.32 }
            local cxm = mx + mw / 2
            self:drawRect(cxm - mw * 0.12, my + mh * 0.02, mw * 0.24, mh * 0.14, a, col.r, col.g, col.b)
            self:drawRect(cxm - mw * 0.25, my + mh * 0.18, mw * 0.5, mh * 0.38, a, col.r, col.g, col.b)
            self:drawRect(cxm - mw * 0.36, my + mh * 0.19, mw * 0.09, mh * 0.33, a, col.r, col.g, col.b)
            self:drawRect(cxm + mw * 0.27, my + mh * 0.19, mw * 0.09, mh * 0.33, a, col.r, col.g, col.b)
            self:drawRect(cxm - mw * 0.22, my + mh * 0.57, mw * 0.18, mh * 0.42, a, col.r, col.g, col.b)
            self:drawRect(cxm + mw * 0.04, my + mh * 0.57, mw * 0.18, mh * 0.42, a, col.r, col.g, col.b)
        end
        local nm = T.fit(c.name, c.w - 8)
        self:drawText(nm, c.x + math.floor((c.w - T.textW(nm)) / 2), c.nameY, G.r, G.g, G.b, a, S.font)
        local tw = 0
        for _, p in ipairs(c.pills) do tw = tw + pillW(p[1]) + 4 end
        local px = c.x + math.floor((c.w - tw + 4) / 2)
        for _, p in ipairs(c.pills) do px = px + pill(self, px, c.pillY, p[1], p[2], a) + 4 end
        -- nodes
        local hover = nil
        local mx, my = nil, nil
        pcall(function() if self:isMouseOver() then mx, my = self:getMouseX(), self:getMouseY() end end)
        for _, nd in ipairs(web.nodes) do
            local na = nd.dead and 0.45 or 1
            pill(self, nd.x, nd.y, nd.label, nd.c, a * na)
            if nd.dead then -- a small cross
                local kx, ky = nd.x + nd.w - 10, nd.y + 2
                self:drawRect(kx + 3, ky, 2, nd.h - 4, a * 0.8, 0.8, 0.8, 0.8)
                self:drawRect(kx, ky + 3, 8, 2, a * 0.8, 0.8, 0.8, 0.8)
            end
            if nd.bitten then self:drawRect(nd.x + 3, nd.y + nd.h - 3, nd.w - 6, 2, a, M.webColors.bite.r, M.webColors.bite.g, M.webColors.bite.b) end
            if mx and mx >= nd.x and mx <= nd.x + nd.w and my >= nd.y and my <= nd.y + nd.h then hover = nd end
        end
        if (web.more or 0) > 0 then self:drawText("+" .. tostring(web.more) .. " more (Close with)", web.area.x, web.area.y, S.dim.r, S.dim.g, S.dim.b, a, S.font) end
        self:drawText(web.hint, x0 + 4, web.hintY, S.dim.r, S.dim.g, S.dim.b, a * 0.8, S.font)
        self.webHover = hover
        if hover then
            local tip = M.webTip(self.uid, hover)
            local w = 0
            for _, l in ipairs(tip) do w = math.max(w, T.textW(l)) end
            local tx, ty = math.min(mx + 14, self.width - w - 20), my + 16
            if ty + #tip * (fh + 1) + 8 > self.height then ty = my - #tip * (fh + 1) - 12 end
            T.box(self, tx, ty, w + 12, #tip * (fh + 1) + 8, S.panel, S.borderDim, a)
            for i, l in ipairs(tip) do self:drawText(l, tx + 6, ty + 4 + (i - 1) * (fh + 1), S.text.r, S.text.g, S.text.b, a, S.font) end
        end
    end

    local baseShow, basePre, baseUp, baseClose = W.showTab, W.prerender, W.onMouseUp, W.close
    function W:showTab(i)
        baseShow(self, i)
        if i == W.TAB.web and not self.pageMode then
            pcall(function() self:webBuild() end)
            self:webModel(true)
        else self:webModel(false) end
    end
    function W:prerender()
        basePre(self)
        if self.activeTab ~= W.TAB.web or self.pageMode then
            if self.webModelIn then self:webModel(false) end
            return
        end
        if M.settings.uiWeb == false then
            self:drawText("The Web tab is off in Settings (uiWeb).", (self.cx or 176) + 4, (self.lay and self.lay.y0 or 160), S.dim.r, S.dim.g, S.dim.b, self.fade or 1, S.font)
            return
        end
        local now = T.now()
        if self.web == nil or (now - (self.webCheckAt or 0) > 1000) then -- the key (a short string) once a second, not every frame
            self.webCheckAt = now
            if self.web == nil or self:webSig() ~= self.webKey then pcall(function() self:webBuild() end) end
        end
        if self.model ~= nil and (not self.webModelIn or self.webModelRef ~= self.model) then self:webModel(true) end -- a new body since
        local ok, err = pcall(function() self:webDraw() end)
        if not ok then M.log("web tab error: " .. tostring(err)) end
    end
    function W:onMouseUp(x, y)
        if self.activeTab == W.TAB.web and not self.pageMode and self.webHover and M.settings.uiWeb ~= false then
            local nd = self.webHover
            -- 0.5.2.10: a name -> the Interactions tab, only what the two of them said to each other (You -> your talks)
            if self.dlgSetFilter and W.TAB.interactions then
                self:showTab(W.TAB.interactions)
                self:dlgSetFilter(nd.you and "you" or "person", (not nd.you) and nd.uid or nil, nd.name)
                return true
            end
            if nd.known and not nd.you and M.openRelationship then
                pcall(M.openRelationship, nd.uid)
                return true
            end
        end
        if baseUp then return baseUp(self, x, y) end
        return ISPanel.onMouseUp(self, x, y)
    end
    function W:close()
        self:webModel(false)
        if baseClose then return baseClose(self) end
    end
end

-- the hover text: their tie, what they think of each other / of you
function M.webTip(centre, nd)
    local out = {}
    local pa = PA()
    if nd.you then
        out[1] = "You - " .. tostring(nd.word)
        out[2] = "Their opinion of you: " .. ((nd.score > 0) and "+" or "") .. tostring(nd.score)
        out[3] = "Click: your talks together"
        return out
    end
    out[1] = tostring(nd.name) .. " - " .. tostring(nd.word) .. (nd.dead and " (dead)" or "")
    out[2] = "Between them: " .. ((nd.score > 0) and "+" or "") .. tostring(nd.score)
    if not nd.dead and M.opinionView and pa then
        pcall(function()
            local r = pa.ActorRegistry.read(nd.uid)
            if r then local v = M.opinionView(r, ALifeSide.you()); out[#out + 1] = "Their opinion of you: " .. ((v > 0) and "+" or "") .. tostring(v) end
        end)
    end
    if nd.bitten then out[#out + 1] = "BITTEN" end
    out[#out + 1] = "Click: what they said to each other"
    return out
end

M.webUIInstall()
return M
