-- A-Life Talk 0.5.0: the Personality page of the Relationship window (layout: preview page_full.png).
--   header   name, "profession · faction · age", divider
--   column 1 donut ring of the top 5 personality traits (thin gaps, soft glow, animated sweep, strongest trait in the
--            centre; hover a segment = matching row highlighted + tooltip), then FEELING RIGHT NOW pills
--   column 2 PERSONALITY rows (dot, name, thin rounded bar scaled to the top value, %), TRAITS, QUIRKS
--   column 3 OPINION OF YOU (big value, label, centre-zero bar), RELATIONSHIPS (5 rows: name, type tag, bond bar),
--            "See all ›" -> the Close with tab
-- Drawing: vanilla ISUIElement only. The ring is made of quads (drawPolygon, else drawTextureAllPoint with a white
-- texture); without either it falls back to a stacked bar so the page always works.
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "UIPage"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("UIPage") end end -- 0.5.1.6 perf label

local M = ALifeLLMTalk
if type(M) ~= "table" then return end
local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, name) return type(t) == "table" and type(t[name]) == "function" end

if M.settings.pageFirst == nil then M.settings.pageFirst = true end
if type(M.fileKeys) == "table" then
    for _, k in ipairs({ "pageFirst", "worldReactions", "playerOrders", "emotions", "darkPersonas", "offscreenLives" }) do
        local have = false
        for _, x in ipairs(M.fileKeys) do if x == k then have = true end end
        if not have then M.fileKeys[#M.fileKeys + 1] = k end
    end
end

M.Page = M.Page or {}
local P = M.Page
local function c255(r, g, b) return { r = r / 255, g = g / 255, b = b / 255 } end
P.C = {
    bg = c255(22, 24, 27), gold = c255(214, 178, 96), txt = c255(222, 224, 228), dim = c255(124, 128, 134),
    track = c255(38, 41, 46), border = c255(70, 62, 40), divider = c255(36, 39, 44), name = c255(238, 238, 238),
    neg = c255(214, 120, 96), negLabel = c255(214, 150, 130), pos = c255(104, 168, 124), zero = c255(90, 94, 100),
    pct = c255(170, 174, 180),
}
P.TAG = { -- relationship type -> tag colour (green-ish good, red-ish bad)
    ["best friend"] = c255(104, 168, 124), sibling = c255(104, 168, 124), parent = c255(104, 168, 124), child = c255(104, 168, 124),
    partner = c255(214, 130, 170), crush = c255(214, 130, 170), admirer = c255(214, 130, 170),
    buddy = c255(120, 170, 190), friend = c255(120, 170, 190), ally = c255(120, 170, 190), comrade = c255(120, 170, 190),
    acquaintance = c255(124, 128, 134), stranger = c255(124, 128, 134),
    rival = c255(214, 150, 80), distrust = c255(214, 150, 80), enemy = c255(201, 92, 84), nemesis = c255(201, 92, 84),
    respect = c255(190, 176, 110), ex = c255(170, 120, 140), -- 0.5.1
}
P.TAGWORD = { ["best friend"] = "Best friend", sibling = "Sibling", parent = "Parent", child = "Child", partner = "Partner",
    crush = "Crush", admirer = "Admirer", buddy = "Buddy", friend = "Friend", ally = "Ally", comrade = "Comrade",
    acquaintance = "Acquaintance", stranger = "Stranger", rival = "Rival", distrust = "Distrust", enemy = "Enemy", nemesis = "Nemesis",
    respect = "Respect", ex = "Ex" }

function P.opinionWord(v)
    v = tonumber(v) or 0
    if v <= -71 then return "Hateful" elseif v <= -41 then return "Hostile" elseif v <= -16 then return "Wary"
    elseif v <= 15 then return "Neutral" elseif v <= 40 then return "Friendly" elseif v <= 70 then return "Trusting" end
    return "Devoted"
end

----------------------------------------------------------------------------------------------------------------
-- data (testable without UI)
----------------------------------------------------------------------------------------------------------------
function M.personalityData(uid, player)
    local pa = PA()
    local live = fn(pa.ActorRegistry, "read") and pa.ActorRegistry.read(tostring(uid)) or nil
    -- 0.5.1.5: far away people keep their page. A-Life deletes the records of travelling NPCs that render out
    -- (and prunes old dormant ones); then we use the people book (Keep.lua) and the saved page snapshot (Profile.lua).
    local rec = live or (M.ghostRecord and M.ghostRecord(uid)) or nil
    local prof = (M.settings.farProfiles ~= false and M.profileOf) and M.profileOf(uid) or nil
    local book = M.bucket and M.bucket("book")[tostring(uid)] or nil
    if type(book) ~= "table" then book = nil end
    local d = { uid = tostring(uid), ghost = live == nil }
    if rec == nil then
        -- never recorded anywhere: one honest page instead of a blank one
        d.unknown, d.name, d.sub = true, "Someone", "Not much known yet"
        d.chart, d.traits, d.quirks, d.feel, d.ties = {}, {}, {}, {}, {}
        d.opinion, d.opinionWord = 0, P.opinionWord(0)
        d.seenText = "Whereabouts unknown"
        return d
    end
    local saved = false
    if live then
        d.name = (fn(pa.Names, "of") and pa.Names.of(rec)) or "Someone"
        if M.shownName and player ~= nil and M.settings.nameDiscovery ~= false then d.name = M.shownName(uid, player) end -- 0.5.1
    else
        d.name = tostring(book and book.name or "Someone")
    end
    if live then
        pcall(function() local who = pa.DialogueRoles.describe(rec, 0); d.role = who and who.label or nil end)
        pcall(function()
            local f = pa.Catalog.faction(rec.factionId)
            d.faction = f and f.general and f.general.name or nil
        end)
    end
    if d.role == nil and prof and prof.role then d.role, saved = prof.role, true end
    if d.faction == nil and prof and prof.fac then d.faction = prof.fac end
    d.faction = d.faction or (rec.factionId and rec.factionId ~= "unknown" and tostring(rec.factionId)) or nil
    if live or (prof == nil or prof.age == nil) then d.age = M.ageOf and M.ageOf(uid) or nil end
    if d.age == nil and prof and prof.age then d.age = prof.age end
    local sub = {}
    if d.role then sub[#sub + 1] = tostring(d.role) end
    if d.faction then sub[#sub + 1] = tostring(d.faction) end
    if d.age then sub[#sub + 1] = "Age " .. tostring(d.age) end
    d.chart = M.traitChart and M.traitChart(uid, 5) or {}
    if #d.chart == 0 and prof and type(prof.chart) == "table" and #prof.chart > 0 then d.chart, saved = prof.chart, true end
    d.traits, d.quirks = {}, {}
    if M.traitLines then d.traits, d.quirks = M.traitLines(uid) end
    if #d.traits == 0 and prof and type(prof.traits) == "table" then d.traits, saved = prof.traits, true end
    if #d.quirks == 0 and prof and type(prof.quirks) == "table" then d.quirks = prof.quirks end
    while #d.quirks > 2 do table.remove(d.quirks) end
    d.feel = {}
    if M.moodOf then
        for i, e in ipairs(M.moodOf(uid, 3) or {}) do
            if i > 3 then break end
            if (e.v or 0) >= 0.12 then d.feel[#d.feel + 1] = { label = e.adj, rgb = e.rgb, v = e.v, why = e.why } end
        end
    end
    local v = 0
    if live then
        pcall(function() v = math.floor((tonumber((pa.NpcOpinion.valueOf(rec, player))) or 0) + 0.5) end)
        if M.opinionView then pcall(function() local vv = M.opinionView(rec, player); if tonumber(vv) then v = math.floor(vv + 0.5) end end) end
    else
        v = tonumber(book and book.value) or tonumber(prof and prof.v) or 0
        if (book == nil or book.value == nil) and M.opinionView then
            pcall(function() local vv = M.opinionView(rec, player); if tonumber(vv) then v = math.floor(vv + 0.5) end end)
        end
    end
    d.opinion, d.opinionWord = v, P.opinionWord(v)
    d.injuries, d.injExtra = nil, 0 -- 0.5.1
    if live and M.injuryLine then
        local okI, parts, st, extra = pcall(M.injuryLine, uid, 2)
        if okI then d.injuries = parts or {}; d.injExtra = tonumber(extra) or 0; d.injState = st end
    end
    d.activity = live and M.activityLine and M.activityLine(uid) or nil -- 0.5.1
    -- away: "last seen X ago near Y" instead of a blank / "Idle"
    if not live then
        d.seenText = M.bookAwayText and M.bookAwayText(uid) or nil
    elseif rec.lifecycle == "dormant" and M.lastSeenOf then
        local okS, ls = pcall(M.lastSeenOf, uid, rec)
        if okS and type(ls) == "table" and ls.text then d.seenText = "Away - " .. tostring(ls.text) end
        if d.seenText == nil then d.seenText = (M.bookAwayText and M.bookAwayText(uid)) or "Away" end
    end
    d.ties = {}
    if M.tiesOf then
        local ok, list = pcall(M.tiesOf, uid, player, 5)
        if ok and type(list) == "table" then
            for _, t in ipairs(list) do
                d.ties[#d.ties + 1] = { uid = t.uid, name = t.name .. (t.dead and " (dead)" or ""), type = t.type,
                    tag = (t.late and ("Late " .. string.lower(tostring(P.TAGWORD[t.type] or t.word or t.type)))) or P.TAGWORD[t.type] or tostring(t.word or t.type),
                    score = t.score, dead = t.dead } -- 0.5.2.6: "Late partner"
            end
        end
    end
    if #d.ties == 0 and prof and type(prof.ties) == "table" then
        for _, t in ipairs(prof.ties) do
            d.ties[#d.ties + 1] = { uid = t.uid, name = tostring(t.name) .. (t.dead and " (dead)" or ""), type = t.type,
                tag = P.TAGWORD[t.type] or tostring(t.word or t.type), score = t.score, dead = t.dead }
        end
        if #d.ties > 0 then saved = true end
    end
    d.fromSaved = saved or nil
    if not live then sub[#sub + 1] = "far away" .. (saved and " (saved page)" or "") end
    d.sub = table.concat(sub, "  \194\183  ") -- middle dot (UTF-8)
    return d
end

----------------------------------------------------------------------------------------------------------------
-- primitives
----------------------------------------------------------------------------------------------------------------
P.white = nil
function P.quad(ui, x1, y1, x2, y2, x3, y3, x4, y4, c, a)
    if P.polyMode ~= "tex" then
        local ok = pcall(function() ui:drawPolygon(nil, x1, y1, x2, y2, x3, y3, x4, y4, c.r, c.g, c.b, a) end)
        if ok then P.polyMode = "poly"; return true end
    end
    if P.white == nil and type(getTexture) == "function" then
        pcall(function() P.white = getTexture("media/ui/ALifeTalk/white.png") end)
    end
    if P.white then
        local ok = pcall(function() ui:drawTextureAllPoint(P.white, x1, y1, x2, y2, x3, y3, x4, y4, c.r, c.g, c.b, a) end)
        if ok then P.polyMode = "tex"; return true end
    end
    P.polyMode = "none"
    return false
end
-- annulus segment from angle a0 to a1 (radians, 0 = up, clockwise)
function P.arc(ui, cx, cy, r0, r1, a0, a1, c, a)
    if a1 <= a0 then return true end
    local steps = math.max(2, math.ceil((a1 - a0) / 0.06))
    local da = (a1 - a0) / steps
    for i = 0, steps - 1 do
        local t0, t1 = a0 + i * da, a0 + (i + 1) * da + 0.004
        local s0, k0, s1, k1 = math.sin(t0), -math.cos(t0), math.sin(t1), -math.cos(t1)
        if not P.quad(ui, cx + s0 * r1, cy + k0 * r1, cx + s1 * r1, cy + k1 * r1, cx + s1 * r0, cy + k1 * r0, cx + s0 * r0, cy + k0 * r0, c, a) then
            return false
        end
    end
    return true
end
-- rounded rectangle from horizontal spans (pills, bars)
function P.rrect(ui, x, y, w, h, r, c, a)
    r = math.min(r, math.floor(h / 2), math.floor(w / 2))
    if r <= 1 then ui:drawRect(x, y, w, h, a, c.r, c.g, c.b); return end
    for dy = 0, h - 1 do
        local inset = 0
        local yy = nil
        if dy < r then yy = r - dy - 0.5 elseif dy >= h - r then yy = dy - (h - r) + 0.5 end
        if yy then inset = r - math.sqrt(math.max(0, r * r - yy * yy)) end
        local i0 = math.floor(inset + 0.5)
        if w - 2 * i0 > 0 then ui:drawRect(x + i0, y + dy, w - 2 * i0, 1, a, c.r, c.g, c.b) end
    end
end
function P.pill(ui, x, y, w, h, fill, line, a)
    P.rrect(ui, x, y, w, h, math.floor(h / 2), line, a)
    P.rrect(ui, x + 1, y + 1, w - 2, h - 2, math.floor(h / 2) - 1, fill, a)
end
function P.bar(ui, x, y, w, frac, c, a, h)
    h = h or 6
    P.rrect(ui, x, y, w, h, math.floor(h / 2), P.C.track, a)
    if frac and frac > 0 then P.rrect(ui, x, y, math.max(h, math.floor(w * math.min(1, frac))), h, math.floor(h / 2), c, a) end
end
local function tw(text, font)
    -- 0.5.2.7 [pt255u]: the shared (cached) measure when the Theme has one - no per-frame re-measuring
    if M.Theme and M.Theme.textW then return M.Theme.textW(text, font) end
    local ok, w = pcall(function() return getTextManager():MeasureStringX(font, tostring(text)) end)
    return ok and w or #tostring(text) * 7
end
local function fh(font)
    local ok, h = pcall(function() return getTextManager():getFontHeight(font) end)
    return ok and h or 14
end
local function dim(c, k) return { r = c.r * k, g = c.g * k, b = c.b * k } end
local function rgb(t) return t and c255(t[1] or 200, t[2] or 200, t[3] or 200) or P.C.txt end
local function atan2(y, x)
    if math.atan2 then return math.atan2(y, x) end
    if x > 0 then return math.atan(y / x) end
    if x < 0 then return math.atan(y / x) + (y >= 0 and math.pi or -math.pi) end
    return y > 0 and math.pi / 2 or (y < 0 and -math.pi / 2 or 0)
end
local function ease(t) t = math.max(0, math.min(1, t)); return 1 - (1 - t) ^ 3 end

----------------------------------------------------------------------------------------------------------------
-- the page. ox/oy = top-left of the 1000 x 560 page (mock coordinates); returns hit areas
----------------------------------------------------------------------------------------------------------------
function P.draw(ui, ox, oy, d, alpha, mx, my, sinceMs)
    local C = P.C
    local Small = UIFont and UIFont.Small
    local Medium = UIFont and UIFont.Medium
    local Large = UIFont and UIFont.Large
    local a = alpha or 1
    local hit = {}
    local function X(v) return ox + v end
    local function Y(v) return oy + v end
    local function text(s, x, y, c, font, al) ui:drawText(tostring(s), X(x), Y(y), c.r, c.g, c.b, (al or 1) * a, font or Small) end
    local function hdr(x, y, s) text(s, x, y, C.gold, Small) end
    -- header
    text(d.name .. (d.muted and "  (deceased)" or ""), 32, 22, d.muted and C.dim or C.name, Large or Medium)
    text(d.sub or "", 32, 54, C.dim, Small)
    ui:drawRect(X(32), Y(84), 1000 - 64, 1, a, C.divider.r, C.divider.g, C.divider.b)
    ui:drawRect(X(315), Y(108), 1, 392, a, C.divider.r, C.divider.g, C.divider.b)
    ui:drawRect(X(655), Y(108), 1, 392, a, C.divider.r, C.divider.g, C.divider.b)

    -- hover: which segment / row
    local chart = d.chart or {}
    local hover = nil
    local cx, cy, r, w = X(170), Y(250), 105, 24
    if mx and my then
        local dx, dy = mx - cx, my - cy
        local dist = math.sqrt(dx * dx + dy * dy)
        if dist >= r - w / 2 - 4 and dist <= r + w / 2 + 4 then
            local ang = atan2(dx, -dy)
            if ang < 0 then ang = ang + 2 * math.pi end
            local acc = 0
            for i, c in ipairs(chart) do
                local span = (c.pct or 0) / 100 * 2 * math.pi
                if ang >= acc and ang < acc + span then hover = i end
                acc = acc + span
            end
        end
        for i = 1, #chart do
            local ry = Y(136 + (i - 1) * 30)
            if mx >= X(336) and mx <= X(640) and my >= ry - 6 and my <= ry + 20 then hover = i end
        end
    end
    hit.hover = hover

    -- column 1: donut
    local sweep = ease((sinceMs or 1e9) / 700) * 2 * math.pi
    local gap = 0.021 -- ~1.2 degrees each side
    local ok = true
    if #chart > 0 then
        -- soft glow (wide, faint rings) then the segments, with a 1 px feather at both edges
        local acc = 0
        for i, c in ipairs(chart) do
            local span = (c.pct or 0) / 100 * 2 * math.pi
            local a0, a1 = acc, math.min(acc + span, sweep)
            local col = rgb(c.rgb)
            if a1 > a0 then
                for k = 1, 3 do
                    ok = ok and P.arc(ui, cx, cy, r - w / 2 - k * 3, r + w / 2 + k * 3, a0, a1, col, 0.035 * a)
                end
            end
            acc = acc + span
        end
        acc = 0
        for i, c in ipairs(chart) do
            local span = (c.pct or 0) / 100 * 2 * math.pi
            local a0, a1 = acc + gap, math.min(acc + span - gap, sweep)
            local col = rgb(c.rgb)
            local pop = (hover == i) and 4 or 0
            if a1 > a0 and ok then
                ok = P.arc(ui, cx, cy, r - w / 2 + pop * 0.25, r + w / 2 + pop, a0, a1, col, a)
                P.arc(ui, cx, cy, r + w / 2 + pop, r + w / 2 + pop + 1, a0, a1, col, 0.35 * a)
                P.arc(ui, cx, cy, r - w / 2 - 1 + pop * 0.25, r - w / 2 + pop * 0.25, a0, a1, col, 0.35 * a)
            end
            acc = acc + span
        end
        if not ok then -- no polygon drawing in this build: stacked bar instead of the ring
            local bx, bw = X(40), 260
            local x = bx
            for _, c in ipairs(chart) do
                local seg = math.floor(bw * (c.pct or 0) / 100)
                local col = rgb(c.rgb)
                ui:drawRect(x, cy - 8, math.max(1, seg - 2), 16, a, col.r, col.g, col.b)
                x = x + seg
            end
        else
            local top = chart[1]
            local label = top and top.label or ""
            local f = Medium or Small
            ui:drawText(label, cx - tw(label, f) / 2, cy - fh(f) + 2, C.name.r, C.name.g, C.name.b, a, f)
            ui:drawText("strongest trait", cx - tw("strongest trait", Small) / 2, cy + 8, C.dim.r, C.dim.g, C.dim.b, a, Small)
        end
    else
        text("They haven't shown much of themselves yet.", 40, 240, C.dim)
    end
    -- FEELING RIGHT NOW
    hdr(40, 392, "FEELING RIGHT NOW")
    local px = 40
    if #(d.feel or {}) == 0 then text("Nothing in particular", 40, 420, C.dim) end
    for _, f in ipairs(d.feel or {}) do
        local col = rgb(f.rgb)
        local w2 = tw(f.label, Small) + 22
        if px + w2 > 300 then break end
        P.pill(ui, X(px), Y(416), w2, 24, dim(col, 0.25), col, a)
        ui:drawText(f.label, X(px + 11), Y(416) + math.floor((24 - fh(Small)) / 2), 0.91, 0.91, 0.92, a, Small)
        if f.why and mx and mx >= X(px) and mx <= X(px + w2) and my >= Y(416) and my <= Y(440) then
            hit.tip = { text = f.label .. ": " .. tostring(f.why), x = mx, y = my }
        end
        px = px + w2 + 8
    end
    -- INJURIES (0.5.1): a small line under the feelings
    if d.injuries ~= nil then
        hdr(40, 456, "INJURIES")
        if #d.injuries == 0 then text("No injuries", 40, 478, C.dim) end
        local red, amber = { r = 0.85, g = 0.36, b = 0.33 }, { r = 0.86, g = 0.64, b = 0.33 }
        for i, w in ipairs(d.injuries) do
            local line = w.text
            if i == #d.injuries and (d.injExtra or 0) > 0 then line = line .. "  +" .. tostring(d.injExtra) end
            while tw(line, Small) > 280 and #line > 8 do line = string.sub(line, 1, #line - 2) end
            text(line, 40, 478 + (i - 1) * 18, (w.bleeding or w.bite) and red or (w.covered and C.dim or amber)) -- 0.5.2.10: a bite is red
        end
    end
    -- ACTIVITY (0.5.1): what they're doing right now
    -- 0.5.1.5: far away -> where / when they were last seen instead of "Idle"
    if d.seenText ~= nil and d.activity == nil then
        local line = tostring(d.seenText)
        local cut = false
        while tw(line, Small) > 280 and #line > 8 do line = string.sub(line, 1, #line - 2); cut = true end
        text(line, 40, 520, C.dim)
        if cut and mx and my and mx >= X(40) and mx <= X(320) and my >= Y(516) and my <= Y(538) then
            hit.tip = { text = tostring(d.seenText), x = mx, y = my }
        end
    else
        local line = "Activity: " .. (d.activity and (string.upper(string.sub(d.activity, 1, 1)) .. string.sub(d.activity, 2)) or "Idle")
        while tw(line, Small) > 280 and #line > 8 do line = string.sub(line, 1, #line - 2) end
        text(line, 40, 520, d.activity and C.txt or C.dim)
    end

    -- column 2: PERSONALITY / TRAITS / QUIRKS
    local x0 = 340
    hdr(x0, 108, "PERSONALITY")
    if #chart == 0 then text("Not much known yet.", x0, 136, C.dim) end -- 0.5.1.5: never an empty section
    local topPct = (chart[1] and chart[1].pct) or 1
    for i, c in ipairs(chart) do
        local y = 136 + (i - 1) * 30
        local col = rgb(c.rgb)
        if hover == i then P.rrect(ui, X(x0 - 8), Y(y - 6), 312, 26, 6, C.track, 0.9 * a) end
        P.rrect(ui, X(x0), Y(y + 3), 9, 9, 4, col, a)
        text(c.label, x0 + 18, y - 1, C.txt)
        P.bar(ui, X(x0 + 110), Y(y + 4), 130, (c.pct or 0) / topPct, col, a)
        local pct = tostring(c.pct or 0) .. "%"
        ui:drawTextRight(pct, X(x0 + 290), Y(y - 1), C.pct.r, C.pct.g, C.pct.b, a, Small)
    end
    if hover and chart[hover] and mx then
        local c = chart[hover]
        hit.tip = { text = c.label .. "  " .. tostring(c.pct) .. "%  -  " .. tostring(c.tip or ""), x = mx, y = my }
    end
    hdr(x0, 300, "TRAITS")
    if #(d.traits or {}) == 0 then text("Not much known yet.", x0, 324, C.dim) end
    for i, t in ipairs(d.traits or {}) do
        if i > 3 then break end
        text("\226\128\162  " .. t, x0, 324 + (i - 1) * 22, C.txt) -- bullet (UTF-8)
    end
    hdr(x0, 404, "QUIRKS")
    if #(d.quirks or {}) == 0 then text("Nothing noticed yet.", x0, 428, C.dim) end
    for i, t in ipairs(d.quirks or {}) do
        if i > 2 then break end
        local s = tostring(t)
        while tw("\226\128\162  " .. s, Small) > 300 and #s > 8 do s = string.sub(s, 1, #s - 4) .. "..." end
        text("\226\128\162  " .. s, x0, 428 + (i - 1) * 22, C.txt)
    end

    -- column 3: OPINION OF YOU + RELATIONSHIPS
    x0 = 680
    hdr(x0, 108, "OPINION OF YOU")
    local v = tonumber(d.opinion) or 0
    local vc = v < -15 and C.neg or (v > 15 and C.pos or C.txt)
    local lc = v < -15 and C.negLabel or (v > 15 and C.pos or C.dim)
    local vs = (v > 0 and "+" or "") .. tostring(v)
    text(vs, x0, 128, vc, Large or Medium)
    text(d.opinionWord or "", x0 + tw(vs, Large or Medium) + 12, 140, lc)
    local bx, bw = x0, 288
    P.rrect(ui, X(bx), Y(174), bw, 6, 3, C.track, a)
    local mid = bx + bw / 2
    local frac = math.max(-1, math.min(1, v / 100))
    if frac < 0 then P.rrect(ui, X(mid + bw / 2 * frac), Y(174), math.max(4, math.floor(-bw / 2 * frac)), 6, 3, vc, a)
    elseif frac > 0 then P.rrect(ui, X(mid), Y(174), math.max(4, math.floor(bw / 2 * frac)), 6, 3, vc, a) end
    ui:drawRect(X(mid), Y(170), 1, 14, a, C.zero.r, C.zero.g, C.zero.b)
    hdr(x0, 212, "RELATIONSHIPS")
    if #(d.ties or {}) == 0 then text("No close ties known.", x0, 240, C.dim) end
    for i, t in ipairs(d.ties or {}) do
        if i > 5 then break end
        local y = 240 + (i - 1) * 44
        local col = P.TAG[t.type] or C.dim
        local al = t.dead and 0.55 or 1
        local nm = tostring(t.name)
        local tag = string.upper(tostring(t.tag))
        local tagW = tw(tag, Small) + 16
        while tw(nm, Small) > 288 - tagW - 10 and #nm > 6 do nm = string.sub(nm, 1, #nm - 4) .. "..." end
        text(nm, x0, y, C.txt, Small, al)
        local tx = x0 + 288 - tagW
        P.pill(ui, X(tx), Y(y - 1), tagW, 18, dim(col, 0.25), col, a * al)
        ui:drawText(tag, X(tx + 8), Y(y - 1) + math.floor((18 - fh(Small)) / 2), col.r, col.g, col.b, a * al, Small)
        P.bar(ui, X(x0), Y(y + 24), 288, math.min(1, math.abs(tonumber(t.score) or 0) / 100), col, a * al)
    end
    local sa = "See all  \226\128\186"
    local sx, sy = x0 + 288 - tw(sa, Small), 468
    local over = mx and mx >= X(sx) and mx <= X(x0 + 288) and my >= Y(sy) and my <= Y(sy + fh(Small))
    text(sa, sx, sy, over and C.name or C.gold)
    hit.seeAll = { x = X(sx), y = Y(sy), w = tw(sa, Small), h = fh(Small) }
    -- tooltip last (on top)
    if hit.tip then
        local s = hit.tip.text
        local w3 = tw(s, Small) + 16
        local tx, ty = hit.tip.x + 14, hit.tip.y + 14
        P.rrect(ui, tx, ty, w3, fh(Small) + 10, 5, C.border, 0.95 * a)
        P.rrect(ui, tx + 1, ty + 1, w3 - 2, fh(Small) + 8, 4, { r = 0.07, g = 0.075, b = 0.085 }, 0.97 * a)
        ui:drawText(s, tx + 8, ty + 5, C.txt.r, C.txt.g, C.txt.b, a, Small)
    end
    return hit
end

----------------------------------------------------------------------------------------------------------------
-- Relationship window integration: the Personality tab turns the window into the wide page
----------------------------------------------------------------------------------------------------------------
local W = ALifeTalkRelationWindow
if type(W) == "table" and W.TAB and not W._pageInstalled then
    W._pageInstalled = true
    local Base = ALifeLLMTalkWindow
    local T = M.Theme
    local S = M.UIStyle
    function W:layoutTabs(page)
        local top = self:contentTop()
        local x0 = page and 24 or self.cx
        local y = page and (top - 2) or (top + 92)
        local x = x0
        for _, b in ipairs(self.tabButtons or {}) do
            b:setX(x); b:setY(y)
            x = x + b:getWidth() + 4
        end
    end
    function W:setPageMode(on)
        on = on == true
        if self.pageMode == on and self.pageModeSet then return end
        self.pageMode, self.pageModeSet = on, true
        local hh = S.headerH
        -- 0.5.2.7 [pt255u]: with uiFixedSize the size never changes here (fitLayout keeps one size for all tabs)
        local fixed = M.settings.uiFixedSize ~= false and self.lay ~= nil and self.lay.fixed
        if on then
            if not fixed then self:setWidth(W.PAGE_W); self:setHeight(W.PAGE_H) end
            self.pageOpenedAt = T.now()
            self.pageData = M.personalityData(self.uid, ALifeSide.you())
        elseif not fixed then
            self:setWidth(W.SMALL_W); self:setHeight(W.SMALL_H)
        end
        pcall(function()
            local sw = getCore():getScreenWidth()
            if self:getX() + self.width > sw then self:setX(math.max(0, sw - self.width - 10)) end
        end)
        if self.model then pcall(function() self.model:setVisible(not on) end) end
        if self.radioBtn then self.radioBtn:setVisible(not on) end
        if self.closeBtn then
            self.closeBtn:setX(self.width - 92); self.closeBtn:setY(self.height - 36)
        end
        if self.closeX then self.closeX:setX(self.width - hh + 3) end
        self:layoutTabs(on)
    end
    local smallPrerender = W.prerender
    function W:prerender()
        if not self.pageMode then return smallPrerender(self) end
        Base.prerender(self)
        local now = T.now()
        if now - (self.refreshedAt or 0) > 2000 then
            pcall(function() self:refresh() end)
            self.pageData = M.personalityData(self.uid, ALifeSide.you()) or self.pageData
        end
        if self.data then self.title = "Relationship - " .. tostring(self.data.name) end
        T.drawTabs(self)
        local d = self.pageData
        if d == nil then return end
        local a = self.fade
        -- page background panel (#16181B) with the gold-brown border, rounded
        local oy = self:contentTop() + 26
        M.Page.rrect(self, 8, oy, self.width - 16, self.height - oy - 44, 10, M.Page.C.border, a)
        M.Page.rrect(self, 9, oy + 1, self.width - 18, self.height - oy - 46, 9, M.Page.C.bg, a)
        local mx, my = nil, nil
        pcall(function() if self:isMouseOver() then mx, my = self:getMouseX(), self:getMouseY() end end)
        -- 0.5.2.7 [pt255u]: the 1000-wide page centred in the (fixed, maybe wider) window, clipped to its panel
        local ox = M.settings.uiFixedSize ~= false and math.max(0, math.floor((self.width - (W.PAGE_W or 1000)) / 2)) or 0
        self.pageOX = ox
        pcall(function() self:setStencilRect(8, oy, self.width - 16, self.height - oy - 44) end)
        local ok, hit = pcall(M.Page.draw, self, ox, oy - 14, d, a, mx, my, now - (self.pageOpenedAt or 0))
        pcall(function() self:clearStencilRect() end)
        if ok then self.pageHit = hit else M.log("personality page error: " .. tostring(hit)) end
    end
    local baseUp = W.onMouseUp
    function W:onMouseUp(x, y)
        local h = self.pageMode and self.pageHit and self.pageHit.seeAll or nil
        if h and x >= h.x and x <= h.x + h.w and y >= h.y - 2 and y <= h.y + h.h + 2 then
            self.activeTab = W.TAB.close
            self:showTab(W.TAB.close)
            return true
        end
        if baseUp then return baseUp(self, x, y) end
        return ISPanel.onMouseUp(self, x, y)
    end
end

return M
