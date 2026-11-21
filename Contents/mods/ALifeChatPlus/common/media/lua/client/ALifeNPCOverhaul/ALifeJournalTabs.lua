-- A-Life NPC Overhaul pre-1.0 (next content patch): OUR WINDOW LIVES IN A-LIFE'S JOURNAL.
-- Every tab of our A-Life window becomes a tab of Project A-Life's own Journal (the way Jeem's "My people" does), so
-- there is one window, A-Life's:
--   Contacts   -> our People        Companions -> our Party        Log -> our Now + Journal (a small row picks which)
--   then Trade, At home, Camp, Build, Radio, Chronicle, AI, our settings ("Overhaul") and Help, each its own tab.
-- A-Life's own Contacts, Companions and Log views are gone from the journal while this is on (Joe's call).
-- Every way in (the key, right-click "A-Life...", the radial, the sidebar, a button that opens one of our pages) opens
-- the journal on that tab. Too many tabs for one row: the row wraps.
-- Our pages are the same windows as before, put inside the journal as its children: no header, no close button, no
-- drag, sized to the journal's content area (and laid out again when the journal is resized). The journal is drawn
-- under them (A-Life draws it in render, after its children; with Jeem, Jeem's draw-under hook does it).
-- Off (setting "journalTabs"), or no A-Life journal (older A-Life, its experiment off): our own window, as before.
-- Client only, per player.
require "ALifeNPCOverhaul/AA_Side"
if ALifeLLMTalk == nil then require "ALifeLLMTalk/ALifeLLMTalk_Main" end
if ALifeLLMTalkWindow == nil then require "ALifeLLMTalk/ALifeLLMTalk_Theme" end
if ALifeLLMTalk == nil or ALifeLLMTalk.hubTabs == nil then require "ALifeLLMTalk/ALifeTalk_Hub" end
local M = ALifeLLMTalk
if type(M) ~= "table" then return end

ALifeJournalTabs = ALifeJournalTabs or {}
local JT = ALifeJournalTabs
JT.VERSION = ALifeSide.MOD_VERSION
JT.PREFIX = "alcp_"
-- A-Life's tabs ours take the place of (in their spot of the row): A-Life id -> our journal tab
JT.replace = { contacts = "people", companions = "party", log = "log" }
-- our hub tabs that share one journal tab (a small row picks which): hub id -> journal tab
JT.groupOf = { now = "log", journal = "log" }
JT.groupOrder = { log = { "now", "journal" } }
-- the order of our journal tabs (any hub tab not listed goes at the end)
JT.order = { "people", "home", "party", "log", "trade", "camp", "build", "radio", "chronicle", "ai" }
JT.labels = { people = "People", party = "Party", log = "Log", settings = "Overhaul Settings" }
-- not in the tab row: buttons top right, next to A-Life's Settings and Esc (right to left: settings, then help)
JT.headerTabs = { "settings", "help" }
JT.headerLabels = { settings = "Overhaul Settings", help = "Help" }
JT.JEEM_TAB = "jimmyPeople"
JT.JEEM_LABEL = "Base"    -- Jeem's "My people" tab, as the row shows it (only the label: Jeem's tab is untouched)
JT.retryMs = 3000         -- a tab whose page failed to open is tried again after this long
JT.cache = JT.cache or {} -- hub id -> our page, kept (detached) while another tab shows; closed with the journal
JT.failed = JT.failed or {}
JT.hits = {}

local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function now() return type(getTimestampMs) == "function" and getTimestampMs() or 0 end
local function tr(key, en) if type(ALifeTr) == "function" then return ALifeTr(key, en) end return en end
local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function call(o, m, ...) if type(o) == "table" and type(o[m]) == "function" then return pcall(o[m], o, ...) end return false end

-- the setting (rule: always configurable). In fileKeys at load, or it resets on restart.
if type(M.settings) == "table" and M.settings.journalTabs == nil then M.settings.journalTabs = true end
if type(M.fileKeys) == "table" then
    local have = false
    for _, k in ipairs(M.fileKeys) do if k == "journalTabs" then have = true end end
    if not have then M.fileKeys[#M.fileKeys + 1] = "journalTabs" end
end

----------------------------------------------------------------------------------------------------------------
-- A-Life's journal
----------------------------------------------------------------------------------------------------------------
function JT.ui()
    local A = PA()
    local ui = A and A.JournalUi or nil
    return type(ui) == "table" and ui or nil
end
function JT.missions()
    local A = PA()
    local Mi = A and A.UI2Missions or nil
    if type(Mi) ~= "table" or type(Mi.Journal) ~= "table" or type(Mi.toggleJournal) ~= "function" then return nil end
    return Mi
end
-- A-Life draws its tabbed journal (JournalUi.on: its journalui_journal experiment; off, the old journal has no tab list)
function JT.journalOn()
    local ui = JT.ui()
    if ui == nil or JT.missions() == nil or type(ui.on) ~= "function" then return false end
    local ok, on = pcall(ui.on)
    return ok and on == true
end
-- our tabs are in the journal now
function JT.on()
    if JT.ready ~= true or type(M.settings) ~= "table" or M.settings.journalTabs == false then return false end
    if fn(M, "hubOn") and not M.hubOn() then return false end
    return JT.journalOn()
end

----------------------------------------------------------------------------------------------------------------
-- the tabs
----------------------------------------------------------------------------------------------------------------
local function shown(t)
    if type(t) ~= "table" then return false end
    if t.show == nil then return true end
    local ok, yes = pcall(t.show)
    return ok and yes == true
end
function JT.hubTab(id)
    for _, t in ipairs(M.hubTabs or {}) do if t.id == id then return t end end
    return nil
end
function JT.hubTabOfClass(class)
    if class == nil then return nil end
    for _, t in ipairs(M.hubTabs or {}) do if t.class == class then return t end end
    return nil
end
function JT.journalTabOf(hubId) return JT.groupOf[hubId] or hubId end
function JT.isOurs(tab) return type(tab) == "string" and string.sub(tab, 1, #JT.PREFIX) == JT.PREFIX end
function JT.strip(tab) return string.sub(tab, #JT.PREFIX + 1) end
-- the hub tabs a journal tab shows (shown ones only, in order)
function JT.members(jid)
    local out = {}
    local order = JT.groupOrder[jid]
    if order then
        for _, id in ipairs(order) do local t = JT.hubTab(id); if shown(t) then out[#out + 1] = t end end
        return out
    end
    local t = JT.hubTab(jid)
    if shown(t) then out[1] = t end
    return out
end
-- our journal tabs: { id = "alcp_<jid>", label, jid }, in JT.order, then any other hub tab
function JT.ourTabs()
    local out, seen = {}, {}
    for _, jid in ipairs(JT.headerTabs) do seen[jid] = true end -- (buttons top right, not tabs)
    local function add(jid)
        if seen[jid] then return end
        seen[jid] = true
        local m = JT.members(jid)
        if #m == 0 then return end
        local label = JT.labels[jid] or m[1].label or jid
        out[#out + 1] = { id = JT.PREFIX .. jid, label = tr("IGUI_ALCP_JTab_" .. jid, label), jid = jid }
    end
    for _, jid in ipairs(JT.order) do add(jid) end
    for _, t in ipairs(M.hubTabs or {}) do add(JT.journalTabOf(t.id)) end
    return out
end
-- A-Life's list with ours merged in: People/At home/Party after Tasks, Log after Reputation, the rest before Jeem's tab
-- (shown as "Base") and A-Life's settings tab. A-Life's Contacts, Companions and Log leave the row.
function JT.merge(list)
    local ours, by = JT.ourTabs(), {}
    for _, t in ipairs(ours) do by[t.jid] = t end
    local out, used = {}, {}
    local function put(jid) local t = by[jid]; if t and not used[jid] then used[jid] = true; out[#out + 1] = t end end
    local function front() put("people"); put("home"); put("party") end
    for _, tab in ipairs(list) do
        if JT.replace[tab.id] == nil then
            if tab.id == JT.JEEM_TAB or tab.id == "settings" then
                front(); put("log")
                for _, t in ipairs(ours) do put(t.jid) end
            end
            if tab.id == JT.JEEM_TAB then
                local copy = {}
                for k, v in pairs(tab) do copy[k] = v end
                copy.label = tr("IGUI_ALCP_JTab_jeemBase", JT.JEEM_LABEL)
                tab = copy
            end
            out[#out + 1] = tab
            if tab.id == "active" then front() end
            if tab.id == "reputation" then front(); put("log") end
        end
    end
    front(); put("log")
    for _, t in ipairs(ours) do put(t.jid) end
    return out
end

----------------------------------------------------------------------------------------------------------------
-- the page in the journal
----------------------------------------------------------------------------------------------------------------
-- JT.cur = { journal, id = hub id, page, box } while one of our pages is in the journal
function JT.alive(page) return type(page) == "table" and page.alcpClosed ~= true end
function JT.showing(win)
    return type(win) == "table" and win.page ~= "settings" and JT.isOurs(win.tab) and JT.on()
end
-- the journal must be drawn under its children (our page is in it)
function JT.under(win)
    local c = JT.cur
    return c ~= nil and c.journal == win and JT.alive(c.page) and JT.showing(win)
end
local function sameBox(a, b) return a ~= nil and b ~= nil and a.x == b.x and a.y == b.y and a.w == b.w and a.h == b.h end
local function mouseDown() return type(isMouseButtonDown) == "function" and isMouseButtonDown(0) == true end

-- a text box of our page has the keyboard
function JT.focusedEntry()
    local c = JT.cur
    if c == nil or not JT.alive(c.page) then return nil end
    local function walk(el, depth)
        if type(el) ~= "table" or depth > 10 then return nil end
        if el.Type == "ISTextEntryBox" then
            local ok, f = call(el, "isFocused")
            if ok and f == true then return el end
        end
        for _, ch in pairs(type(el.children) == "table" and el.children or {}) do
            local hit = walk(ch, depth + 1)
            if hit then return hit end
        end
        return nil
    end
    return walk(c.page, 0)
end
function JT.unfocus()
    local e = JT.focusedEntry()
    while e ~= nil do
        call(e, "unfocus")
        local nxt = JT.focusedEntry()
        if nxt == e then break end
        e = nxt
    end
end

-- off the journal (another tab, the settings page): the page leaves it, kept as it is for when you come back
function JT.leave()
    local c = JT.cur
    if c == nil then return false end
    JT.unfocus()
    JT.cur = nil
    if JT.alive(c.page) then
        call(c.page, "setVisible", false)
        if c.page.parent ~= nil then call(c.page.parent, "removeChild", c.page) end
        c.page.parent = nil
        JT.cache[c.id] = c.page
    end
    return true
end

-- the page fits a new box: its own layout (our hub pages, the settings page), its resize hook, else it is built again
function JT.fit(page, box)
    call(page, "setX", box.x); call(page, "setY", box.y)
    call(page, "setWidth", box.w); call(page, "setHeight", box.h)
    page.alcpBox = { x = box.x, y = box.y, w = box.w, h = box.h }
    if type(page.layout) == "function" then
        if type(page.buildButtons) == "function" then pcall(page.buildButtons, page) end
        local ok = pcall(page.layout, page)
        if page.body ~= nil then call(page.body, "paginate") end
        return ok
    end
    if type(page.onResized) == "function" then return (pcall(page.onResized, page)) end
    return "rebuild"
end

-- a page goes in the journal at box: before it is built (no header, no close key, no drag, no corner grip), or again
function JT.attach(journal, page, hubId, box)
    if JT.cur ~= nil and JT.cur.page ~= page then JT.leave() end
    page.alcpEmbedded = true
    page.alcpClosed = nil
    page.keepOnScreen = false
    page.moveWithMouse = false
    if page.rsKey ~= nil then page.alcpRsKey, page.rsKey = page.rsKey, nil end
    if page.javaObject == nil then
        page.x, page.y, page.width, page.height = box.x, box.y, box.w, box.h
        page.alcpBox = { x = box.x, y = box.y, w = box.w, h = box.h }
        call(page, "initialise")
        journal:addChild(page)   -- (builds it: createChildren at this size)
    else
        journal:addChild(page)
        if not sameBox(page.alcpBox, box) then
            if JT.fit(page, box) == "rebuild" then JT.cache[hubId] = nil; page.alcpClosed = true; return JT.rebuild(journal, hubId, box) end
        end
    end
    call(page, "setVisible", true)
    if page.closeX ~= nil then call(page.closeX, "setVisible", false) end
    call(page, "setX", box.x); call(page, "setY", box.y)
    JT.cache[hubId] = nil
    JT.cur = { journal = journal, id = hubId, page = page, box = box }
    if type(M.hubState) == "table" then M.hubState.last = hubId end
    return page
end

-- open hub tab hubId's page into the journal (its own opener builds it; Theme.open hands it to us: JT.adopt)
function JT.rebuild(journal, hubId, box)
    local t = JT.hubTab(hubId)
    if t == nil or type(t.open) ~= "function" then return nil end
    JT.embedding = { journal = journal, id = hubId, box = box }
    local ok, err = pcall(t.open)
    JT.embedding = nil
    if not ok then
        JT.failed[hubId] = now()
        print("[ALifeJournalTabs] the " .. tostring(hubId) .. " tab failed to open (retry in " .. JT.retryMs .. " ms): " .. tostring(err))
        return nil
    end
    local c = JT.cur
    if c == nil or c.id ~= hubId or c.journal ~= journal then JT.failed[hubId] = now(); return nil end
    JT.failed[hubId] = nil
    return c.page
end

-- show hub tab hubId in the journal at box (the kept page if there is one)
function JT.show(journal, hubId, box)
    local c = JT.cur
    if c ~= nil and (c.id ~= hubId or c.journal ~= journal or not JT.alive(c.page)) then JT.leave(); c = nil end
    if c ~= nil then
        if not sameBox(c.box, box) and not mouseDown() then
            c.box = box
            if not sameBox(c.page.alcpBox, box) and JT.fit(c.page, box) == "rebuild" then
                local old = c.page
                JT.cur = nil
                call(old, "close")
                return JT.rebuild(journal, hubId, box)
            end
        end
        return c.page
    end
    local kept = JT.cache[hubId]
    if JT.alive(kept) then return JT.attach(journal, kept, hubId, box) end
    JT.cache[hubId] = nil
    local f = JT.failed[hubId]
    if f ~= nil and now() - f < JT.retryMs then return nil end
    return JT.rebuild(journal, hubId, box)
end

-- Theme.open of one of our tab pages while our tabs are in the journal: the page goes in the journal (opened on its
-- tab) instead of on the screen. True when taken.
function JT.adopt(page)
    if type(page) ~= "table" or not JT.on() then return false end
    local t = JT.hubTabOfClass(page.Type)
    if t == nil then return false end
    local e = JT.embedding
    if e == nil or e.id ~= t.id then
        e = JT.openJournalFor(t.id)
        if e == nil then return false end
    end
    JT.cache[t.id] = nil
    JT.attach(e.journal, page, t.id, e.box)
    return true
end

-- where the content goes before the journal has drawn it (the first draw moves it where it belongs)
function JT.guessBox(journal, jid)
    local w, h = tonumber(journal.width) or 640, tonumber(journal.height) or 440
    local L = JT.lastBox
    local subH = (#JT.members(jid) > 1) and JT.subRowH() or 0
    if L ~= nil then
        local top = L.y - (L.sub or 0) + subH
        return { x = L.x, y = top, w = math.max(100, w - 2 * L.x), h = math.max(100, h - top - L.x) }
    end
    local px = function(v) local Ch = PA() and PA().UI2Chrome; if Ch and Ch.px then return Ch.px(v) end return v end
    local top = px(150) + subH
    return { x = px(22), y = top, w = math.max(100, w - 2 * px(22)), h = math.max(100, h - top - px(22)) }
end

-- the journal open (opened if it isn't) on hub tab hubId's journal tab: { journal, id, box }, or nil
function JT.openJournalFor(hubId)
    local Mi = JT.missions()
    if Mi == nil then return nil end
    if Mi.journal == nil then
        local ok, err = pcall(Mi.toggleJournal)
        if not ok then print("[ALifeJournalTabs] the journal failed to open: " .. tostring(err)) end
    end
    local win = Mi.journal
    if type(win) ~= "table" then return nil end
    local jid = JT.journalTabOf(hubId)
    if JT.isHeaderTab(JT.PREFIX .. jid) and win.tab ~= nil and not JT.isHeaderTab(win.tab) then win.alcpBackTab = win.tab end
    win.tab, win.page, win.selected = JT.PREFIX .. jid, "main", nil
    win.alcpSub = win.alcpSub or {}
    win.alcpSub[jid] = hubId
    call(win, "bringToTop")
    return { journal = win, id = hubId, box = JT.guessBox(win, jid) }
end

-- open our hub tab id (or the last one used) in the journal; returns its page
function JT.openHub(id)
    local last = type(M.hubState) == "table" and M.hubState.last or nil
    local t = JT.hubTab(id or last or "people")
    if not shown(t) then t = JT.hubTab("now") end
    if not shown(t) then t = JT.hubTab("people") end
    if t == nil then return nil end
    local e = JT.openJournalFor(t.id)
    if e == nil then return nil end
    local c = JT.cur
    if c ~= nil and c.id == t.id and c.journal == e.journal and JT.alive(c.page) then return c.page end
    JT.failed[t.id] = nil
    return JT.show(e.journal, t.id, e.box)
end

-- the journal closes: our pages close with it (built again on the next open)
function JT.releaseAll()
    local c = JT.cur
    JT.cur = nil
    local pages = {}
    if c ~= nil and JT.alive(c.page) then pages[#pages + 1] = c.page; JT.unfocus() end
    for _, p in pairs(JT.cache) do if JT.alive(p) then pages[#pages + 1] = p end end
    JT.cache = {}
    for _, p in ipairs(pages) do call(p, "close") end
    return #pages
end

----------------------------------------------------------------------------------------------------------------
-- drawing our tab
----------------------------------------------------------------------------------------------------------------
function JT.subRowH()
    local A = PA()
    local Ch, Kit = A and A.UI2Chrome, A and A.UI2Kit
    if Ch == nil or Kit == nil then return 40 end
    return math.max(Ch.px(28), Kit.fontH(UIFont.Small) + 8) + Ch.px(10)
end
local function over(win, r)
    local ok, mx = call(win, "getMouseX")
    local ok2, my = call(win, "getMouseY")
    mx, my = ok and tonumber(mx) or -1, ok2 and tonumber(my) or -1
    return mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h
end
-- the small row of a shared tab (Log: Now, Journal), A-Life's tab look. Returns its height.
function JT.drawSub(win, members, current, x, y, a)
    local A = PA()
    local Ch, T = A.UI2Chrome, A.UI2Theme
    local font = UIFont.Small
    local th = JT.subRowH() - Ch.px(10)
    local gap, pad = Ch.px(6), Ch.px(14)
    local at = x
    for _, t in ipairs(members) do
        local label = tr("IGUI_ALCP_Tab_" .. t.id, t.label)
        label = (T and fn(T, "caseText")) and T.caseText(label) or string.upper(label)
        local tw = Ch.boldWidth(font, label, 0) + 2 * pad
        local r = { x = at, y = y, w = tw, h = th, sub = t.id }
        Ch.tab(win, at, y, tw, th, label, t.id == current or over(win, r), a, font)
        JT.hits[#JT.hits + 1] = r
        at = at + tw + gap
    end
    return JT.subRowH()
end
function JT.drawMessage(win, text, x, y, a)
    local A = PA()
    local Kit, T = A.UI2Kit, A.UI2Theme
    local c = (T and fn(T, "color")) and T.color("faint") or nil
    pcall(Kit.text, win, text, x, y + 4, c, a, UIFont.Small)
end
-- our tab's content (A-Life's draw falls through to drawTasks for a tab it doesn't know)
function JT.drawContent(win, x, y, w, h, a)
    JT.hits = {}
    local jid = JT.strip(win.tab)
    local members = JT.members(jid)
    if #members == 0 then win.tab = "active"; JT.leave(); return "gone" end
    win.alcpSub = win.alcpSub or {}
    local cur = win.alcpSub[jid]
    local ok = false
    for _, t in ipairs(members) do if t.id == cur then ok = true end end
    if not ok then cur = members[1].id; win.alcpSub[jid] = cur end
    local top = y
    if #members > 1 then top = top + JT.drawSub(win, members, cur, x, y, a) end
    local box = { x = x, y = top, w = w, h = math.max(1, h - (top - y)) }
    JT.lastBox = { x = x, y = top, sub = top - y }
    local page = JT.show(win, cur, box)
    if page == nil then
        JT.drawMessage(win, tr("IGUI_ALCP_JTab_Failed", "This page couldn't open. Trying again..."), box.x, box.y, a)
        return "failed"
    end
    return "page"
end

----------------------------------------------------------------------------------------------------------------
-- a row of tabs too long for the journal wraps (A-Life's Chrome.tabs draws one row; ours makes it long)
----------------------------------------------------------------------------------------------------------------
function JT.tabsRows(el, x, y, w, tabs, active, a, hit, font)
    local A = PA()
    local Ch, Kit, T = A.UI2Chrome, A.UI2Kit, A.UI2Theme
    font = font or UIFont.Small
    local h = math.max(Ch.px(28), Kit.fontH(font) + 8)
    local gap, pad, rowGap = Ch.px(6), Ch.px(7), Ch.px(4)
    local left, right = x + h + gap, x + w - h - gap
    Ch.keyChip(el, x, y, h, "Q", a, font, true)
    hit.prev = { x = x, y = y, w = h, h = h }
    local at, row = left, 0
    for _, tab in ipairs(tabs) do
        local label = T.caseText(tab.label)
        local tw = Ch.boldWidth(font, label, 0) + pad * 2
        if at + tw > right and at > left then row = row + 1; at = left end
        local ty = y + row * (h + rowGap)
        Ch.tab(el, at, ty, tw, h, label, tab.id == active, a, font)
        hit[#hit + 1] = { x = at, y = ty, w = tw, h = h, id = tab.id }
        at = at + tw + gap
    end
    local ey = y + row * (h + rowGap)
    Ch.keyChip(el, at, ey, h, "E", a, font, true)
    hit.next = { x = at, y = ey, w = h, h = h }
    return (row + 1) * h + row * rowGap
end
function JT.tooWide(w, tabs, font)
    local A = PA()
    local Ch, Kit = A.UI2Chrome, A.UI2Kit
    font = font or UIFont.Small
    local h = math.max(Ch.px(28), Kit.fontH(font) + 8)
    local gap = Ch.px(6)
    return Ch.tabsWidth(tabs, font, 3, gap) > w - (h + gap) * 2
end

----------------------------------------------------------------------------------------------------------------
-- top right: Overhaul Settings and Help, left of A-Life's Settings button (or its Esc), A-Life's button look
----------------------------------------------------------------------------------------------------------------
function JT.drawHeader(win, a, pad, headH)
    local A = PA()
    local Ch, Kit = A.UI2Chrome, A.UI2Kit
    local hit = type(win.hit) == "table" and win.hit or nil
    if hit == nil then return end
    hit.alcpTop = {}
    local left = (hit.gear and hit.gear.x) or (hit.close and hit.close.x)
    if left == nil then return end
    local keyH = Kit.fontH(UIFont.Small) + Ch.px(8)
    local ky = pad + math.floor((headH - keyH) / 2)
    local x = left
    for _, jid in ipairs(JT.headerTabs) do
        if #JT.members(jid) > 0 then
            local label = tr("IGUI_ALCP_JTop_" .. jid, JT.headerLabels[jid] or jid)
            local bw = Ch.buttonWidth(label, UIFont.Small, Ch.px(30))
            x = x - Ch.px(12) - bw
            local r = { x = x, y = ky, w = bw, h = keyH, jid = jid }
            local here = win.tab == JT.PREFIX .. jid and win.page ~= "settings"
            Ch.button(win, x, ky, bw, keyH, label, here and "primary" or nil, over(win, r), a, UIFont.Small)
            hit.alcpTop[#hit.alcpTop + 1] = r
        end
    end
end
function JT.headerWrap(original)
    return function(win, a, page, ...)
        local pad, headH = original(win, a, page, ...)
        if JT.on() and pad ~= nil and headH ~= nil then
            local ok, err = pcall(JT.drawHeader, win, a, pad, headH)
            if not ok and not JT.headFailed then JT.headFailed = true; print("[ALifeJournalTabs] top-right buttons failed (logged once): " .. tostring(err)) end
        end
        return pad, headH
    end
end
-- a top-right button: that page in the journal; pressed again, back to the tab you were on
function JT.clickTop(win, x, y)
    local hit = type(win.hit) == "table" and win.hit or {}
    for _, r in ipairs(hit.alcpTop or {}) do
        if x >= r.x and y >= r.y and x <= r.x + r.w and y <= r.y + r.h then
            local id = JT.PREFIX .. r.jid
            if win.tab == id and win.page ~= "settings" then
                win.tab = win.alcpBackTab or "active"
            else
                if win.tab ~= nil and win.tab ~= id and not JT.isHeaderTab(win.tab) then win.alcpBackTab = win.tab end
                win.tab = id
            end
            win.page, win.selected = "main", nil
            return true
        end
    end
    return false
end
function JT.isHeaderTab(tab)
    if not JT.isOurs(tab) then return false end
    local jid = JT.strip(tab)
    for _, h in ipairs(JT.headerTabs) do if h == jid then return true end end
    return false
end

----------------------------------------------------------------------------------------------------------------
-- hooks
----------------------------------------------------------------------------------------------------------------
function JT.tabsWrap(original)
    return function(...)
        local list = original(...)
        if type(list) ~= "table" or not JT.on() then return list end
        local ok, out = pcall(JT.merge, list)
        return ok and out or list
    end
end
function JT.drawWrap(original)
    return function(win, ...)
        if JT.cur ~= nil and JT.cur.journal == win and not JT.showing(win) then pcall(JT.leave) end
        return original(win, ...)
    end
end
function JT.drawTasksWrap(original)
    return function(win, x, y, w, h, a, ...)
        if not JT.showing(win) then return original(win, x, y, w, h, a, ...) end
        local ok, err = pcall(JT.drawContent, win, x, y, w, h, a)
        if not ok and not JT.drawFailed then
            JT.drawFailed = true
            print("[ALifeJournalTabs] our tab failed to draw (logged once): " .. tostring(err))
        end
    end
end
function JT.click(win, x, y)
    for _, r in ipairs(JT.hits or {}) do
        if r.sub and x >= r.x and y >= r.y and x <= r.x + r.w and y <= r.y + r.h then
            local jid = JT.strip(win.tab)
            win.alcpSub = win.alcpSub or {}
            win.alcpSub[jid] = r.sub
            return true
        end
    end
    -- (a click on the page area that the page let through: never A-Life's task rows)
    local c = JT.cur
    if c ~= nil and c.journal == win and x >= c.box.x and y >= c.box.y and x <= c.box.x + c.box.w and y <= c.box.y + c.box.h then return true end
    return false
end
function JT.clickWrap(original)
    return function(win, x, y, ...)
        if JT.on() then
            local ok, hit = pcall(JT.clickTop, win, x, y)
            if ok and hit then return true end
        end
        if JT.showing(win) then
            local ok, hit = pcall(JT.click, win, x, y)
            if ok and hit then return true end
        end
        return original(win, x, y, ...)
    end
end
function JT.wheelWrap(original)
    return function(win, delta, ...)
        if JT.showing(win) then
            local c = JT.cur
            local body = c and c.page and (c.page.body or c.page.list) or nil
            if body ~= nil and type(body.onMouseWheel) == "function" then pcall(body.onMouseWheel, body, delta) end
            return true
        end
        return original(win, delta, ...)
    end
end
function JT.escapeWrap(original)
    return function(win, ...)
        if JT.showing(win) and JT.focusedEntry() ~= nil then JT.unfocus(); return true end
        return original(win, ...)
    end
end
-- Q / E / Esc typed into a text box of our page are not the journal's (no tab step; Esc leaves the box). Whether a box
-- had the keyboard is noted at the press: Esc can let go of it before the release.
function JT.consumeWrap(original)
    return function(self, key, ...)
        if JT.showing(self) then
            self.alcpTyping = self.alcpTyping or {}
            self.alcpTyping[key] = JT.focusedEntry() ~= nil or nil
        end
        return original(self, key, ...)
    end
end
function JT.keyWrap(original)
    return function(self, key, ...)
        local K = Keyboard
        if K ~= nil and (key == K.KEY_Q or key == K.KEY_E or key == K.KEY_ESCAPE) and JT.showing(self) then
            local keys = self.alcpTyping
            local typed = (keys ~= nil and keys[key] == true) or JT.focusedEntry() ~= nil
            if keys ~= nil then keys[key] = nil end
            if typed then
                if key == K.KEY_ESCAPE then JT.unfocus() end
                return
            end
        end
        return original(self, key, ...)
    end
end
function JT.closeWrap(original)
    return function(self, ...)
        pcall(JT.releaseAll)   -- (one journal: every page of ours goes with it)
        return original(self, ...)
    end
end
-- the journal drawn under its children while our page is in it. With Jeem's draw-under hook in, Jeem does it.
function JT.jeemUnder()
    local Jm = ProjectALifeJimmy
    if type(Jm) ~= "table" or type(Jm.wrapped) ~= "table" or type(Jm.JournalSize) ~= "table" then return false end
    local under = Jm.JournalSize.under
    return Jm.wrapped["journal_size:ProjectALife.UI2Missions.Journal.prerender"] ~= nil
        and Jm.wrapped["journal_size:ProjectALife.UI2Missions.Journal.render"] ~= nil
        and type(under) == "table" and under.alcp_tabs ~= nil
end
function JT.prerenderWrap(original)
    return function(self, ...)
        local r = original(self, ...)
        if JT.jeemUnder() then self.alcpUnder = nil; return r end
        local u = JT.under(self)
        self.alcpUnder = u
        if u then
            local Mi = JT.missions()
            local ok, err = pcall(Mi.drawJournal, self)
            if not ok and not JT.underFailed then JT.underFailed = true; print("[ALifeJournalTabs] journal under our page failed (logged once): " .. tostring(err)) end
        end
        return r
    end
end
function JT.renderWrap(original)
    return function(self, ...)
        if JT.jeemUnder() then return original(self, ...) end
        local u = self.alcpUnder
        self.alcpUnder = nil
        if u == nil then u = JT.under(self) end
        if u then return end
        return original(self, ...)
    end
end

-- our windows, while inside the journal: no box or header (the journal is the background), no grip, a close that
-- takes the page out of the journal
function JT.installPageHooks()
    local W = ALifeLLMTalkWindow
    if W == nil or W._alcpJournal then return W ~= nil end
    W._alcpJournal = true
    local pre, top, close, down = W.prerender, W.contentTop, W.close, W.onMouseDown
    W.prerender = function(self, ...)
        if self.alcpEmbedded then
            local S = M.UIStyle
            local t = now() - (self.openedAt or 0)
            self.fade = math.max(0, math.min(1, t / ((S and S.fadeMs) or 150)))
            return
        end
        return pre(self, ...)
    end
    W.contentTop = function(self, ...)
        if self.alcpEmbedded then return 4 end
        return top(self, ...)
    end
    W.onMouseDown = function(self, x, y, ...)
        if self.alcpEmbedded then return ISPanel.onMouseDown(self, x, y) end
        return down(self, x, y, ...)
    end
    W.close = function(self, ...)
        if self.alcpEmbedded then
            self.alcpClosed = true
            if JT.cur ~= nil and JT.cur.page == self then JT.unfocus(); JT.cur = nil end
            for id, p in pairs(JT.cache) do if p == self then JT.cache[id] = nil end end
            if self.parent ~= nil then call(self.parent, "removeChild", self) end
            self.parent = nil   -- (vanilla removeChild leaves it)
        end
        return close(self, ...)
    end
    local HP = ALifeTalkHubPage
    if HP ~= nil then
        local hdown, hrender = HP.onMouseDown, HP.render
        HP.onMouseDown = function(self, x, y, ...)
            if self.alcpEmbedded then return ISPanel.onMouseDown(self, x, y) end
            return hdown(self, x, y, ...)
        end
        HP.render = function(self, ...)
            if self.alcpEmbedded then return ALifeLLMTalkWindow.render(self, ...) end
            return hrender(self, ...)
        end
    end
    local T = M.Theme
    if T ~= nil and type(T.open) == "function" then
        local open = T.open
        T.open = function(win, ...)
            local ok, taken = pcall(JT.adopt, win)
            if ok and taken then return win end
            if not ok then print("[ALifeJournalTabs] into the journal failed, own window: " .. tostring(taken)) end
            return open(win, ...)
        end
    end
    return true
end

-- every way in opens the journal on our tab
function JT.installHub()
    if M._alcpJournalHub or not fn(M, "hubOpen") or not fn(M, "hubToggle") then return M._alcpJournalHub == true end
    M._alcpJournalHub = true
    local open, toggle = M.hubOpen, M.hubToggle
    M.hubOpen = function(id, ...)
        if JT.on() then
            local ok, w = pcall(JT.openHub, id)
            if ok and w ~= nil then return w end
            if not ok then print("[ALifeJournalTabs] open in the journal failed: " .. tostring(w)) end
            local Mi = JT.missions()
            if Mi ~= nil and Mi.journal ~= nil then return nil end  -- (the journal shows the tab; its page retries)
        end
        return open(id, ...)
    end
    M.hubToggle = function(id, ...)
        if JT.on() then
            local Mi = JT.missions()
            local win = Mi and Mi.journal or nil
            local c = JT.cur
            if win ~= nil and JT.showing(win) and (id == nil or (c ~= nil and c.id == id)) then
                call(win, "close")
                return false
            end
            M.hubOpen(id)
            return true
        end
        return toggle(id, ...)
    end
    return true
end

local function wrap(owner, key, make)
    if type(owner) ~= "table" or type(owner[key]) ~= "function" then return false end
    owner[key] = make(owner[key])
    return true
end
JT.uiHooks = { tabs = "tabsWrap", draw = "drawWrap", drawTasks = "drawTasksWrap", click = "clickWrap", wheel = "wheelWrap", escape = "escapeWrap", header = "headerWrap" }
JT.winHooks = { close = "closeWrap", onKeyRelease = "keyWrap", isKeyConsumed = "consumeWrap", prerender = "prerenderWrap", render = "renderWrap" }

function JT.install()
    if JT.ready then return true end
    local ui, Mi = JT.ui(), JT.missions()
    local A = PA()
    if ui == nil or Mi == nil or A == nil or type(A.UI2Chrome) ~= "table" or type(A.UI2Kit) ~= "table" or type(A.UI2Theme) ~= "table" then return false end
    for k in pairs(JT.uiHooks) do if k ~= "header" and type(ui[k]) ~= "function" then return false end end -- (no header: no top-right buttons, the rest works)
    for k in pairs(JT.winHooks) do if type(Mi.Journal[k]) ~= "function" then return false end end
    if type(A.UI2Chrome.tabs) ~= "function" or type(Mi.drawJournal) ~= "function" then return false end
    if not JT.installPageHooks() then return false end
    for k, make in pairs(JT.uiHooks) do wrap(ui, k, JT[make]) end
    for k, make in pairs(JT.winHooks) do wrap(Mi.Journal, k, JT[make]) end
    local Ch = A.UI2Chrome
    local tabs0 = Ch.tabs
    Ch.tabs = function(el, x, y, w, tabs, active, a, hit, font, ...)
        if type(el) == "table" and el.Type == "ALifeUI2Journal" and JT.on() and type(tabs) == "table" and type(hit) == "table" then
            local ok, wide = pcall(JT.tooWide, w, tabs, font)
            if ok and wide then
                local ok2, h = pcall(JT.tabsRows, el, x, y, w, tabs, active, a, hit, font)
                if ok2 then return h end
            end
        end
        return tabs0(el, x, y, w, tabs, active, a, hit, font, ...)
    end
    local Jm = ProjectALifeJimmy
    if type(Jm) == "table" and type(Jm.JournalSize) == "table" and type(Jm.JournalSize.drawUnder) == "function" then
        pcall(Jm.JournalSize.drawUnder, "alcp_tabs", JT.under)
    end
    JT.installHub()
    -- the switch in our settings
    if type(M.settingRows) == "table" then
        local have = false
        for _, r in ipairs(M.settingRows) do if r[1] == "journalTabs" then have = true end end
        if not have then M.settingRows[#M.settingRows + 1] = { "journalTabs", "Our tabs inside A-Life's journal (off: our own window)" } end
    end
    JT.ready = true
    print("[ALifeJournalTabs] ready " .. JT.VERSION .. ": our tabs in A-Life's journal (People, At home, Party, Log, Trade, Camp, Build, Radio, Chronicle, AI; top right: Overhaul Settings, Help; Jeem's My people shown as Base)")
    return true
end

if type(Events) == "table" and Events.OnGameStart then Events.OnGameStart.Add(function() pcall(JT.install) end) end

return JT
