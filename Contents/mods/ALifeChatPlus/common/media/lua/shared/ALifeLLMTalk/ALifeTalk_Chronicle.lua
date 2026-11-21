-- A-Life NPC Overhaul 0.9.1 (Legacy): THE CHRONICLE, client side.
--   * Who tells it: a resident who was there (the one closest to the person it's about, else one of the camp), and
--     how: warm if they like you (A-Life NpcOpinion), bitter if they don't, plain otherwise.
--   * Client-side events: deaths at camp and "no time for a funeral" (the camp log, ALifeTalk_Camp cpLog), funerals
--     (CampGrief's funeral card), survivors' stories ending (ALifeGoals.outcome), feasts (ALifeSeasonsCamp.feast).
--     The shared ones (lieutenant, the camp's votes, capture, backing a side) are hooked in shared/ALifeChronicle.
--   * The AI (when on, single player / host) rewrites an entry in the narrator's voice (mode "letter": a written note).
--   * Write it down: right-click a notebook you can write in (and a pen), or the Chronicle tab's button: one chapter a
--     page (vanilla addPage, like writing a note yourself), the book renamed "Chronicle of <camp>". A later character
--     who finds it reads what happened.
--   * Export: the Chronicle tab writes Zomboid/Lua/ALifeChronicle.txt (vanilla getFileWriter).
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalk_Chronicle") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
require "ALifeNPCOverhaul/ALifeChronicle"
local M = ALifeLLMTalk
local C = ALifeChronicle
if type(M) ~= "table" or type(C) ~= "table" then return end
ALifeChronicleUI = ALifeChronicleUI or {}
local U = ALifeChronicleUI
local TAG = "[ALifeChronicleUI]"
U.VERSION = ALifeSide.MOD_VERSION
U.list = U.list or {}
U.stats = { added = 0, ai = 0, pages = 0, exports = 0 }

local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function playerOf() -- pre-1.0 MP (P6): on a server the watchers write for the camp's player
    if ALifeSide.mpServer() and ALifeSide.cur == nil and type(M) == "table" and type(M.homePlayer) == "function" then return M.homePlayer() end
    local p = nil; pcall(function() p = ALifeSide.you() end); return p
end
local function isMP() return ALifeSide.client() end
local function log(m) print(TAG .. " " .. tostring(m)) end
local function tr(k, en, ...)
    if ALifeTr then return ALifeTr("IGUI_ALCP_Chron_" .. k, en, ...) end
    local a = { ... }
    return (string.gsub(en, "{(%d)}", function(i) return tostring(a[tonumber(i)] or "") end))
end
local function rec(uid) local r = nil; pcall(function() r = PA().ActorRegistry.read(tostring(uid)) end); return r end
local function first(uid)
    local r = rec(uid)
    local m = r and type(r.memory) == "table" and r.memory or {}
    if type(m.personFirst) == "string" and m.personFirst ~= "" then return m.personFirst end
    local n = nil
    pcall(function() n = PA().Names.of(r) end)
    return n and (string.match(tostring(n), "^(%S+)") or tostring(n)) or nil
end
U.first = first

-- a first name from the camp log back to the person (the camp's dead first, then the living)
function U.uidByName(name)
    name = tostring(name or "")
    if name == "" then return nil end
    if fn(M, "grData") then
        local ok, g = pcall(M.grData)
        if ok and type(g) == "table" and type(g.dead) == "table" then
            for i = #g.dead, 1, -1 do if g.dead[i].name == name then return tostring(g.dead[i].uid) end end
        end
    end
    for _, u in ipairs(U.people(playerOf())) do if first(u) == name then return tostring(u) end end
    return nil
end
-- the camp now (residents)
function U.people(player)
    local out = {}
    if fn(M, "cpPeople") then pcall(function() out = M.cpPeople(player) or {} end) end
    return out
end
-- who tells it: the resident closest to the person it's about; else one picked by the entry (stable)
function U.narrator(player, aboutUid, seed)
    local ppl = U.people(player)
    if #ppl == 0 then return nil end
    local best, bestV = nil, 0.2
    if aboutUid and fn(M, "closeness") then
        for _, u in ipairs(ppl) do
            if tostring(u) ~= tostring(aboutUid) then
                local ok, v = pcall(M.closeness, tostring(u), tostring(aboutUid))
                if ok and tonumber(v) and v > bestV then best, bestV = u, v end
            end
        end
    end
    if best then return tostring(best) end
    local h = 0
    for i = 1, #tostring(seed or "") do h = (h * 31 + string.byte(tostring(seed), i)) % 100000 end
    local pick = ppl[(h % #ppl) + 1]
    if tostring(pick) == tostring(aboutUid) and #ppl > 1 then pick = ppl[((h + 1) % #ppl) + 1] end
    return tostring(pick)
end
-- how they tell it: what they think of you
function U.bias(uid, player)
    local v = 0
    pcall(function() v = tonumber((PA().NpcOpinion.valueOf(rec(uid), player))) or 0 end)
    if v >= 25 then return "warm" elseif v <= -15 then return "bitter" end
    return "plain"
end

-- write one (single player: straight in; multiplayer: the server writes it)
function U.note(k, who, uid, what)
    if not C.on() then return nil end
    local player = playerOf()
    local by = U.narrator(player, uid, tostring(k) .. tostring(who) .. tostring(what))
    local ev = { k = k, who = who, uid = uid, what = what, by = by, byName = by and first(by) or nil, bias = by and U.bias(by, player) or "plain" }
    U.stats.added = U.stats.added + 1
    if isMP() then
        if fn(ALifeCmd, "send") and player then pcall(ALifeCmd.send, player, "chronAdd", ev) end
        return ev
    end
    return C.add(ev)
end

-- the AI tells it in their voice (letter mode: written, never spoken). Single player / host only (M.react checks).
function U.askAI(e)
    if C.setting("chronAI") == false or not fn(M, "react") or type(e) ~= "table" or e.by == nil then return false end
    local player = playerOf()
    local r = rec(e.by)
    if r == nil or player == nil then return false end
    local sh = nil
    pcall(function() sh = PA().Companions.shellOf(tostring(e.by)) end)
    local l = { record = r, shell = sh }
    local fact = tostring(e.who ~= "" and (e.who .. ": ") or "") .. tostring(e.what)
    local tone = e.bias == "warm" and "fondly" or (e.bias == "bitter" and "with some bitterness" or "plainly")
    local ok, sent = pcall(M.react, "letter", l, player, { what = "You are writing one entry in your camp's chronicle, the history of the camp, about this: "
        .. fact .. ". Write it " .. tone .. ", like you were there (2 short sentences, past tense, no date)", style = "a written chronicle entry, plain words", maxWords = 40 },
        { key = "chron:" .. tostring(e.id), keyCooldownMs = 1, modeCooldownMs = 20000, onDone = function(job, res)
            if type(res) == "table" and type(res.text) == "string" and #res.text > 8 then
                if isMP() then pcall(ALifeCmd.send, playerOf(), "chronAI", { id = e.id, text = res.text }) else C.setAI(e.id, res.text) end
                U.stats.ai = U.stats.ai + 1
            end
        end })
    return ok and sent == true
end
C.onAdded = function(e) if e.big then pcall(U.askAI, e) end end

-- ------------------------------------------------------------------------------------------------ client hooks
function U.hook()
    local n = 0
    -- the camp log: deaths, no funeral
    if C.wrap(M, "cpLog", function(res, kind, text)
        text = tostring(text or "")
        if kind ~= "death" then return end
        local skipped = string.match(text, "^you had no time for (.+)'s funeral$")
        if skipped then U.note("nofuneral", skipped, U.uidByName(skipped), "no time for the funeral"); return end
        local name, how = string.match(text, "^(%S+) died, (.+)$")
        if name == nil then name = string.match(text, "^(%S+) died") end
        if name then U.note("death", name, U.uidByName(name), how and ("killed by " .. how) or "they died") end
    end) then n = n + 1 end
    -- stories ending (ALifeGoals.outcome(uid, row, g))
    if C.wrap(ALifeGoals, "outcome", function(res, uid, row, g)
        if type(row) ~= "table" then return end
        local o = tostring(row.outcome or "")
        local t = tostring(row.tn or "them")
        local what = ({ family = "found " .. t .. " again", amends = "made it right with " .. t, revenge = "got their revenge on " .. t,
            prodigal = "brought " .. t .. " home after they walked out", guilt = "went where " .. t .. " died, and said goodbye" })[row.k or ""] or "their story ended"
        if o == "helped" and row.k == "family" and type(g) == "table" and g.fate == "dead" then what = "learned " .. t .. " was dead"
        elseif o == "clean" then what = row.k == "second" and "got clean on their second try" or "got clean"
        elseif o == "gone" then what = row.k == "amends" and ("never made it right with " .. t .. " before they died") or (t .. " died before they could settle it")
        elseif o == "relapsed" then what = "started drinking again"
        elseif o == "warned" then what = "never got to " .. t .. ": someone warned them"
        elseif o == "grave" then what = "learned " .. t .. " was dead, and never saw them again"
        elseif o == "letgo" then what = row.k == "revenge" and ("let go of their hate for " .. t) or ("made their peace about " .. t)
        elseif o == "bitter" then what = "gave up on " .. t .. ", and it turned them bitter" end
        U.note("story", first(uid) or "someone", tostring(uid), what)
    end) then n = n + 1 end
    -- feasts (only the ones that happened: the feast count went up)
    if type(ALifeSeasonsCamp) == "table" and fn(ALifeSeasonsCamp, "feast") and not rawget(ALifeSeasonsCamp, "_chron_feast") then
        local L = ALifeSeasonsCamp
        local orig = L.feast
        L.feast = function(player, b, people, id, title, memText, ...)
            local before = type(L.metrics) == "table" and L.metrics.feasts or 0
            local r = orig(player, b, people, id, title, memText, ...)
            pcall(function()
                if type(L.metrics) == "table" and (L.metrics.feasts or 0) > (before or 0) then
                    U.note("feast", nil, nil, "We held " .. tostring(title) .. ", " .. #(people or {}) .. " of us at the table")
                end
            end)
            return r
        end
        rawset(L, "_chron_feast", true)
        n = n + 1
    end
    U.hooked = n
    return n
end
-- funerals: CampGrief keeps the one being held (g.funeral); write it once
function U.watchFuneral()
    if not fn(M, "grData") then return false end
    local ok, g = pcall(M.grData)
    if not ok or type(g) ~= "table" or type(g.funeral) ~= "table" then return false end
    local f = g.funeral
    if U.lastFuneral == tostring(f.uid) .. ":" .. tostring(f.day) then return false end
    U.lastFuneral = tostring(f.uid) .. ":" .. tostring(f.day)
    U.note("funeral", tostring(f.name or "someone"), tostring(f.uid), "we buried them at dusk")
    return true
end
-- the leader: you, from the first entry (0.9.2 writes heirs)
function U.leaderCheck()
    local p = playerOf()
    if p == nil or C.leader() ~= nil then return false end
    local n = C.playerName(p)
    if n == nil then return false end
    if isMP() then return false end
    return C.setLeader(n, "first")
end

-- ------------------------------------------------------------------------------------------------ the list
function U.refresh()
    if not isMP() then U.list = C.view(200); return U.list end
    local p = playerOf()
    if p and fn(ALifeCmd, "send") then pcall(ALifeCmd.send, p, "chronAsk", {}) end
    return U.list
end
if fn(ALifeCmd, "onClient") then ALifeCmd.onClient("chronList", function(a) if type(a) == "table" and type(a.list) == "table" then U.list = a.list; if U.win then pcall(function() U.win:refresh() end) end end end) end
function U.campName(player)
    local b = nil
    if fn(M, "wzBase") then pcall(function() b = M.wzBase(player) end) end
    return (type(b) == "table" and b.name) or "our camp"
end

-- ------------------------------------------------------------------------------------------------ the notebook
local function hasPen(inv)
    for _, t in ipairs({ "WRITE", "BLUE_PEN", "PEN", "PENCIL", "RED_PEN", "GREEN_PEN" }) do
        local ok, yes = pcall(function() return inv:containsTagRecurse(ItemTag[t]) end)
        if ok and yes then return true end
    end
    return false
end
U.hasPen = hasPen
-- write it into this notebook: one chapter a page (as many as it has), returns pages written or nil, why
function U.writeBook(player, book)
    if player == nil or book == nil then return nil, "none" end
    local inv = nil
    pcall(function() inv = player:getInventory() end)
    if inv == nil or not hasPen(inv) then return nil, "pen" end
    local okW, can = pcall(function() return book:canBeWrite() end)
    if not okW or not can then return nil, "book" end
    local locked = nil
    pcall(function() locked = book:getLockedBy() end)
    if locked and locked ~= player:getUsername() then return nil, "locked" end
    local pages = 0
    pcall(function() pages = tonumber(book:getPageToWrite()) or 0 end)
    if pages <= 0 then return nil, "book" end
    if not isMP() then U.list = C.view(200) end
    local chapters = C.chapters()
    if #chapters == 0 then return nil, "empty" end
    local start = math.max(1, #chapters - pages + 1) -- the newest chapters if the book is too thin
    local n = 0
    for i = start, #chapters do
        n = n + 1
        local ok = pcall(function() book:addPage(n, string.sub(C.chapterText(chapters[i]), 1, 1800)) end)
        if not ok then return nil, "write" end
    end
    pcall(function() book:setName(tr("BookName", "Chronicle of {1}", U.campName(player))); book:setCustomName(true) end)
    U.stats.pages = U.stats.pages + n
    return n
end
function U.findBook(player)
    local found = nil
    pcall(function()
        local items = player:getInventory():getItems()
        for i = 0, items:size() - 1 do
            local it = items:get(i)
            if it:getCategory() == "Literature" and it:canBeWrite() then found = it; return end
        end
    end)
    return found
end
U.WHY = { pen = "You need a pen or pencil.", book = "You need a notebook or journal you can write in.", locked = "Someone else's book.",
    empty = "Nothing to write yet.", write = "Couldn't write in it.", none = "You need a notebook or journal you can write in." }
function U.write(player, book)
    book = book or U.findBook(player)
    local n, why = U.writeBook(player, book)
    local msg = n and tr("Wrote", "You wrote the camp's chronicle into the book ({1} pages).", n) or tr("Why_" .. tostring(why), U.WHY[tostring(why)] or "Couldn't.")
    if fn(M, "momToast") then pcall(M.momToast, msg) end
    return n, why
end
-- export to Zomboid/Lua/<file> (vanilla getFileWriter(name, createIfNull, append))
function U.export(player, file)
    file = file or "ALifeChronicle.txt"
    if not isMP() then U.list = C.view(200) end
    local text = C.text(U.campName(player))
    local ok = pcall(function()
        local w = getFileWriter(file, true, false)
        w:write(text)
        w:close()
    end)
    if ok then U.stats.exports = U.stats.exports + 1 end
    if fn(M, "momToast") then pcall(M.momToast, ok and tr("Exported", "Chronicle saved to Zomboid/Lua/{1}", file) or tr("ExportFail", "Couldn't save the file.")) end
    return ok, text
end
-- right-click a writable notebook in your hands / bag
function U.fillInv(playerNum, context, items)
    if not C.on() then return end
    local player = getSpecificPlayer(playerNum)
    for _, v in ipairs(items or {}) do
        local it = type(v) == "table" and v.items and v.items[1] or v
        local ok, can = pcall(function() return it:getCategory() == "Literature" and it:canBeWrite() end)
        if ok and can then
            context:addOption(tr("WriteOpt", "Write the camp's chronicle in it"), it, function(book) U.write(player, book) end)
            return
        end
    end
end
if type(Events) == "table" and Events.OnFillInventoryObjectContextMenu then
    Events.OnFillInventoryObjectContextMenu.Add(function(a, b, c) pcall(U.fillInv, a, b, c) end)
end

-- ------------------------------------------------------------------------------------------------ the tab
function U.pageText(kit)
    local list = U.refresh()
    if #list == 0 then return kit.DIM .. tr("Empty", "Nothing written yet. The camp writes down what happens to it: deaths, funerals, who came and who left, what the people in charge decided, feasts, how people's stories ended.") .. " <LINE> " end
    local out = {}
    local ways = (type(ALifeTraditions) == "table" and fn(ALifeTraditions, "list")) and ALifeTraditions.list() or {}
    if #ways > 0 then out[#out + 1] = kit.GOLD .. tr("Ways", "Our ways: {1}.", table.concat(ways, "; ")) .. " <LINE> <LINE> " end
    local ok, chapters = pcall(C.chapters) -- global ModData: the server's copy reaches clients (ModData.transmit)
    if not ok then chapters = {} end
    for i = #chapters, 1, -1 do
        local ch = chapters[i]
        out[#out + 1] = kit.GOLD .. tostring(ch.title) .. " <LINE> "
        for j = #ch.entries, 1, -1 do
            local e = ch.entries[j]
            out[#out + 1] = tostring(C.telling(e)) .. (e.byName and (kit.DIM .. " - " .. e.byName) or "") .. " <LINE> "
        end
        out[#out + 1] = " <LINE> "
    end
    return table.concat(out)
end
function U.addTab()
    if U.tabAdded then return true end
    local kit = M.winKit
    if type(kit) ~= "table" or not fn(M, "hubAddTab") or ALifeTalkHubPage == nil then return false end
    local P = kit.page("ALifeTalkChroniclePage", "Chronicle", "chronicle",
        tr("Tip", "<SIZE:medium> Chronicle <LINE> <SIZE:small> The camp's history, told by the people who were there, each in their own way. Write it into a notebook so it outlasts you, or save it to a file."))
    function P:createChildren() ALifeTalkHubPage.createChildren(self); U.win = self end
    function P:text() return U.pageText(kit) end
    function P:actions()
        return {
            { label = tr("WriteBtn", "Write it in a notebook"), tip = tr("WriteTip", "Needs a notebook or journal and a pen or pencil. One chapter a page."), fn = function() U.write(playerOf()) end },
            { label = tr("ExportBtn", "Save to a file"), tip = tr("ExportTip", "Zomboid/Lua/ALifeChronicle.txt, to share."), fn = function() U.export(playerOf()) end },
        }
    end
    function P:onPageClose() if U.win == self then U.win = nil end end
    M.hubAddTab({ id = "chronicle", label = "Chronicle", class = "ALifeTalkChroniclePage", open = function() U.refresh(); return kit.openPage(P, "winChronicle") end,
        ref = function() return M.winChronicle end, show = function() return C.on() end }, "settings")
    U.tabAdded = true
    return true
end

function U.install()
    pcall(U.addTab)
    pcall(U.hook)
    pcall(C.hookShared)
    if type(M.settingRows) == "table" then
        local have = {}
        for _, r in ipairs(M.settingRows) do have[r[1]] = true end
        for _, r in ipairs({
            { "chronicle", "Chronicle: the camp writes down its history (Chronicle tab)" },
            { "chronRate", "Chronicle: share of small events written down (%)", { 25, 50, 100 } },
            { "chronMax", "Chronicle: most entries kept", { 100, 300, 600 } },
            { "chronAI", "Chronicle: the AI tells entries in the narrator's voice (when the AI is on)" },
        }) do if not have[r[1]] then M.settingRows[#M.settingRows + 1] = r end end
    end
    if type(M.settingCatOf) == "table" then for k in pairs(C.DEFAULTS) do M.settingCatOf[k] = M.settingCatOf[k] or "Your camp and base" end end
    print(TAG .. " ready v" .. U.VERSION .. ": Chronicle tab " .. (U.tabAdded and "on" or "OFF") .. ", " .. tostring(U.hooked or 0) .. " client hooks, "
        .. tostring(C.hookedShared or 0) .. " shared hooks")
end
if type(Events) == "table" and Events.OnGameStart then Events.OnGameStart.Add(function() pcall(U.install) end) end
if type(Events) == "table" and Events.EveryTenMinutes then
    Events.EveryTenMinutes.Add(function() pcall(U.watchFuneral); pcall(U.leaderCheck) end)
end
return U
