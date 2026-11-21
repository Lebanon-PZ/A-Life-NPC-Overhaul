-- A-Life NPC Overhaul pre-1.0: KEEP STOCKED (docs/PLAN-RIM.md #4). "Keep 40 planks." You set a number, your people
-- work toward it, and they tell you when something you watch runs low.
--   * Planks / logs (Camp > Keep stocked): with Fortify on, builders saw logs from your stockpile into planks until the
--     stockpile holds the number (the same real sawing NPC bases do: a saw, a log, an animation, ALifeTalk_Build). Logs
--     only get chopped when "only your materials" is off (Fortify's own rule). Nothing comes from nothing.
--   * Anything else (Camp > Keep stocked on a container: pick a thing it holds): counted across your drop points and
--     the stockpile while you're near (loaded containers only). Short: once a day someone says so, a letter, the AI
--     knows, and NPC talk can bring it up. Nobody makes it up for you: you or a run has to bring it.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeKeepStocked") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
if ALifeCampKit == nil then require "ALifeNPCOverhaul/ALifeCampKit" end
if type(ALifeLLMTalk) ~= "table" or type(ALifeLLMTalk.cpAddJob) ~= "function" then require "ALifeLLMTalk/ALifeTalk_Camp" end
local K = ALifeCampKit
ALifeKeepStocked = ALifeKeepStocked or {}
local S = ALifeKeepStocked
local TAG = "[ALifeKeepStocked]"
S.VERSION = ALifeSide.MOD_VERSION
S.DEFAULTS = {
    keepStock = true,     -- you can set numbers to keep stocked
    keepStockHour = 9,    -- hour of the day someone mentions what's short
    keepStockMax = 12,    -- most things on the watch list
    keepStockTiles = 70,  -- you must be this close to the base for counting (containers must be loaded)
}
K.reg(S.DEFAULTS, {
    { "keepStock", "Camp: keep stocked (builders saw planks to your number, people say what's short)" },
    { "keepStockHour", "Keep stocked: hour someone mentions what's short", { 7, 8, 9, 12, 18 } },
    { "keepStockMax", "Keep stocked: most things on the watch list", { 5, 8, 12, 20 } },
}, "Your camp and base")
S.TARGETS = { 0, 5, 10, 20, 40, 80 }
S.BUILD = { plank = { full = "Base.Plank", label = "Planks" }, log = { full = "Base.Log", label = "Logs" } }
S.stats = { stockProjects = 0, short = 0 }
local function set(k) return K.set(S.DEFAULTS, k) end
local function num(k) return K.num(S.DEFAULTS, k) end
local function log(m) K.log(TAG, m) end
function S.on() return set("keepStock") ~= false end
function S.store()
    local s = K.bucket("rimKeepStocked")
    s.build = type(s.build) == "table" and s.build or {}   -- plank / log -> n
    s.watch = type(s.watch) == "table" and s.watch or {}   -- list of { full, label, n }
    return s
end

-- 1) planks / logs through the base-building system: a "stock" project when nothing else is to be built
function S.stockProject(b, c)
    local M = K.M()
    if not S.on() or type(b) ~= "table" or not b.playerBase or M == nil or not K.fn(M, "bdHave") then return nil end
    local s = S.store()
    for _, key in ipairs({ "plank", "log" }) do
        local want = tonumber(s.build[key]) or 0
        if want > 0 then
            local have = 0
            pcall(function() have = M.bdHave(b, key, c) end)
            if have < want then
                S.stats.stockProjects = S.stats.stockProjects + 1
                return { kind = "stock", need = { [key] = want } } -- no target: the build step never runs, only saw / chop
            end
        end
    end
    return nil
end
function S.hookBuild()
    local M = K.M()
    if M == nil then return 0 end
    return K.wrap(M, "bdProject", "stock:bdProject", function(orig)
        return function(b, h, c, ...)
            local p = orig(b, h, c, ...)
            if p ~= nil then return p end
            return S.stockProject(b, c)
        end
    end) and 1 or 0
end

-- 2) the watch list: counted across drop points + the stockpile
function S.containers(player)
    local M = K.M()
    local out = {}
    if M == nil then return out end
    local H = M.cpH
    local seen = {}
    local function add(p)
        if type(p) ~= "table" then return end
        local k = math.floor(p.x) .. ":" .. math.floor(p.y) .. ":" .. math.floor(p.z or 0)
        if seen[k] then return end
        seen[k] = true
        local sq = H.sqAt(p.x, p.y, p.z)
        local c = sq and H.containerOn(sq) or nil
        if c then out[#out + 1] = c end
    end
    for _, list in pairs(M.cpData().drops or {}) do for _, p in ipairs(type(list) == "table" and list or {}) do add(p) end end
    if K.fn(M, "cpFortData") then add(M.cpFortData().depot) end
    return out
end
function S.count(full, player)
    local n = 0
    for _, c in ipairs(S.containers(player)) do
        pcall(function() n = n + (tonumber(c:getCountTypeRecurse(full)) or 0) end)
    end
    return n
end
function S.near(player)
    local b = K.base(player)
    local px, py = K.pos(player)
    return b ~= nil and px ~= nil and K.d2(b.x, b.y, px, py) <= num("keepStockTiles") ^ 2
end
-- what's short right now: { { label, have, want } } (only while you're near: containers must be loaded)
function S.short(player)
    local out = {}
    if not S.on() or not S.near(player) then return out end
    local s = S.store()
    for key, n in pairs(s.build) do
        local def = S.BUILD[key]
        if def and (tonumber(n) or 0) > 0 then
            local have = S.count(def.full, player)
            if have < n then out[#out + 1] = { label = def.label, have = have, want = n } end
        end
    end
    for _, w in ipairs(s.watch) do
        local have = S.count(w.full, player)
        if have < (tonumber(w.n) or 0) then out[#out + 1] = { label = w.label, have = have, want = w.n } end
    end
    table.sort(out, function(a, b) return a.label < b.label end)
    return out
end
-- words, never numbers: "almost out of" / "low on"
function S.words(row) if row.have <= 0 then return "out of " .. string.lower(row.label) end; if row.have * 2 < row.want then return "low on " .. string.lower(row.label) end; return "running low on " .. string.lower(row.label) end
S.lastShort = {}
function S.hourly(player, h)
    if not S.on() or player == nil then return 0 end
    if K.hourOfDay() ~= num("keepStockHour") then return 0 end
    local s = S.store()
    local day = K.day()
    if s.saidDay == day then return 0 end
    local short = S.short(player)
    S.lastShort = short
    if #short == 0 then return 0 end
    s.saidDay = day
    S.stats.short = S.stats.short + 1
    local parts = {}
    for i, r in ipairs(short) do if i <= 3 then parts[#parts + 1] = S.words(r) end end
    local text = "We're " .. table.concat(parts, ", ") .. "."
    local people = K.people(player)
    if #people > 0 then K.say(people[1 + (day % #people)], text) end
    K.letter("Stores: " .. text, 220, 200, 140)
    K.campLog("short", text)
    return #short
end
function S.extra(req, player, listener)
    if not S.on() or #S.lastShort == 0 then return nil end
    local parts = {}
    for i, r in ipairs(S.lastShort) do if i <= 3 then parts[#parts + 1] = S.words(r) end end
    return "The camp is " .. table.concat(parts, ", ") .. "."
end

-- menu: Camp > Keep stocked
function S.menu(child, off, player, x, y, z, inRange, why)
    if not S.on() then return end
    local M = K.M()
    local s = S.store()
    local m, mo = child("Keep stocked")
    for _, key in ipairs({ "plank", "log" }) do
        local def = S.BUILD[key]
        local cur = tonumber(s.build[key]) or 0
        local sm = ISContextMenu:getNew(m)
        m:addSubMenu(m:addOption(def.label .. (cur > 0 and (" (keep " .. cur .. ")") or "")), sm)
        for _, n in ipairs(S.TARGETS) do
            local o = sm:addOption(n == 0 and "Don't" or ("Keep " .. n), nil, function() K.run("ksBuild", player, key, n) end)
            if n == cur then off(o, "Already this.") end
        end
    end
    -- a thing in this container: watch it
    local H = M.cpH
    local sq = H.sqAt(x, y, z)
    local c = sq and H.containerOn(sq) or nil
    if c then
        local kinds, order = {}, {}
        pcall(function()
            local items = c:getItems()
            for i = 0, items:size() - 1 do
                local it = items:get(i)
                local full = it:getFullType()
                if full and kinds[full] == nil and #order < 12 then kinds[full] = it:getDisplayName(); order[#order + 1] = full end
            end
        end)
        if #order > 0 then
            local wm = ISContextMenu:getNew(m)
            m:addSubMenu(m:addOption("Watch a thing in here"), wm)
            for _, full in ipairs(order) do
                local im = ISContextMenu:getNew(wm)
                wm:addSubMenu(wm:addOption(tostring(kinds[full])), im)
                for _, n in ipairs(S.TARGETS) do
                    im:addOption(n == 0 and "Stop watching" or ("Keep at least " .. n), nil, function() K.run("ksWatch", player, full, kinds[full], n) end)
                end
            end
        end
    end
    if #s.watch > 0 then
        local lm = ISContextMenu:getNew(m)
        m:addSubMenu(m:addOption("Watched (" .. #s.watch .. ")"), lm)
        for _, w in ipairs(s.watch) do lm:addOption("Stop watching " .. tostring(w.label), nil, function() K.run("ksWatch", player, w.full, w.label, 0) end) end
    end
end
-- pre-1.0 MP (P4): this menu's writes (SP directly; MP on the server as the sender, values checked)
local function okTarget(n) for _, t in ipairs(S.TARGETS) do if t == n then return true end end; return false end
K.act("ksBuild", function(player, key, n)
    key, n = tostring(key), tonumber(n)
    local def = S.BUILD[key]
    if def == nil or n == nil or not okTarget(n) then return false end
    S.store().build[key] = n > 0 and n or nil
    if n > 0 then
        local M = K.M()
        local fortOn = K.fn(M, "cpFortOn") and M.cpFortOn()
        K.letter("Keep " .. n .. " " .. string.lower(def.label) .. " in the stockpile." .. (fortOn and "" or " (Fortify must be on: builders saw from the stockpile.)"), 210, 200, 150)
    end
end)
K.act("ksWatch", function(player, full, label, n)
    n = tonumber(n)
    if full == nil or n == nil or not okTarget(n) then return false end
    return S.setWatch(tostring(full), label ~= nil and string.sub(tostring(label), 1, 80) or nil, n)
end)
function S.setWatch(full, label, n)
    local s = S.store()
    for i = #s.watch, 1, -1 do if s.watch[i].full == full then table.remove(s.watch, i) end end
    if (tonumber(n) or 0) > 0 then
        if #s.watch >= num("keepStockMax") then K.letter("The watch list is full."); return false end
        s.watch[#s.watch + 1] = { full = tostring(full), label = tostring(label or full), n = n }
        K.letter("Keep at least " .. n .. " " .. tostring(label) .. ". They'll say when it runs low.", 210, 200, 150)
    end
    return true
end
function S.install()
    local n = S.hookBuild()
    if not S._menu then K.addMenu(function(...) return S.menu(...) end); S._menu = true end
    if not S._extra then K.addExtra(S.extra); S._extra = true end
    if not S._hourly then K.hourly(TAG, S.hourly); S._hourly = true end
    return n
end
pcall(S.install)
if type(Events) == "table" and Events.OnGameStart ~= nil then
    Events.OnGameStart.Add(function()
        local ok, n = pcall(S.install)
        log("ready v" .. S.VERSION .. ": keep stocked " .. (S.on() and "on" or "off") .. " (" .. tostring(ok and n or 0) .. "/1 build hook)")
    end)
end
return S
