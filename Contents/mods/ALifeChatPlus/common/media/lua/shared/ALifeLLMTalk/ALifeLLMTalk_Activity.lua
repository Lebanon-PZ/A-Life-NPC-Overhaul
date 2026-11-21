-- 0.5.1.3: with ALifeTalkPatch 1.4 the activity OWNS the NPC (A-Life's decision step is skipped while it runs, so they
-- really walk there, sit / sleep / cook and stay); A-Life gets them back instantly on danger. [ALifeTalk][Activity] logs.
-- A-Life Talk 0.5.1: NPCs do more than wander - an individual activity / daily-routine layer.
-- Idle NPCs near you pick an activity by time of day, weather, needs (tired, hurt, drunk, hungry from Off-screen
-- Lives), personality, profession (A-Life background), mood and where they are (indoors / camp / shelter). It runs
-- through ALifeTalkPatch (P.activityStart: A-Life's own hold order at an anchor + A-Life animation presets; seats with
-- A-Life's SeatApi; beds found by sprite). Everything yields at once to danger (patch: engaged / zombies / hostile /
-- talk / orders / following) and our own systems (pause, territory, threats) because those take the NPC through
-- A-Life orders, which end the activity.
-- Holed up (A-Life shelter: memory.shelterBuildingId or the patch's shelter state): barricade (patch shelterCare:
-- vanilla barricade with planks + nails + hammer, else close / lock doors, curtains, lights off at night), use the
-- furniture (couch / chair through SeatApi, beds at night), lie down to rest when tired / injured / depressed / drunk.
-- Furniture dragging is NOT done (moving IsoObjects from Lua can duplicate or destroy them) - doors are the fallback.
-- "What are you doing?" gets an accurate answer (req.activity for the AI, a stock answer otherwise).
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_Activity") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Activity"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Activity") end end -- 0.5.1.6 perf label

local M = ALifeLLMTalk
if type(M) ~= "table" then return end

local function setting(key, default)
    if M.settings[key] == nil then M.settings[key] = default end
    if type(M.fileKeys) == "table" then
        local have = false
        for _, x in ipairs(M.fileKeys) do if x == key then have = true end end
        if not have then M.fileKeys[#M.fileKeys + 1] = key end
    end
end
setting("activityLog", true)

local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, name) return type(t) == "table" and type(t[name]) == "function" end
local function log(msg) M.log(msg) end
local function nowMs() return M.nowMs() end
local function patch() return M.patch and M.patch() or nil end
local function pos(o) if o == nil then return nil end; local x, y, z = nil, nil, nil; pcall(function() x, y, z = o:getX(), o:getY(), o:getZ() end); return x, y, z end
local function hash(s) local h = 5381; s = tostring(s); for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end; return h end
local function pick(list, seed) return list[(hash(seed) % #list) + 1] end
local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end

-- 0.5.1.3: [ALifeTalk][Activity] console log (setting activityLog) - chosen / started / walking / arrived / posed /
-- reasserted / interrupted / finished / skipped (+ why), and a summary every minute while anything happens.
M.actLogAt = {}
M.actStats = { chosen = 0, started = 0, reasserted = 0, interrupted = 0, finished = 0, skipped = 0, why = {} }
function M.actLog(msg, key, gapMs)
    if M.settings.activityLog == false then return end
    if key ~= nil then
        local now = nowMs()
        if now - (M.actLogAt[key] or -1e12) < (gapMs or 120000) then return end
        M.actLogAt[key] = now
    end
    ALifeHealth.note("[ALifeTalk][Activity]", msg)
end
local function actName(uid)
    local n = nil
    pcall(function() local pa = PA(); n = pa.Names.of(pa.ActorRegistry.read(tostring(uid))) end)
    return tostring(n or "someone") .. " (" .. tostring(uid) .. ")"
end
M.actName = actName
local function skipped(uid, why)
    local key = "skip|" .. tostring(uid) .. "|" .. tostring(why)
    if nowMs() - (M.actLogAt[key] or -1e12) < 120000 then return end -- same NPC + reason: counted / logged once per 2 min
    M.actLogAt[key] = nowMs()
    M.actStats.skipped = M.actStats.skipped + 1
    M.actStats.why[why] = (M.actStats.why[why] or 0) + 1
    if M.settings.activityLog ~= false then print("[ALifeTalk][Activity] skipped " .. actName(uid) .. ": " .. tostring(why)) end
end
M.actSkipped = skipped

if M.settings.activity == nil then M.settings.activity = true end
if type(M.fileKeys) == "table" then
    local have = false
    for _, x in ipairs(M.fileKeys) do if x == "activity" then have = true end end
    if not have then M.fileKeys[#M.fileKeys + 1] = "activity" end
end
-- 0.5.1.3: tuning from the user's own edit (more NPCs doing something, sooner, more sitting / chatting)
M.actCfg = { tickMs = 4000, tiles = 45, maxActive = 16, perTick = 3, restMs = 45000, seatTiles = 8, bedTiles = 10, summaryMs = 60000 }
M.activities = M.activities or {} -- uid -> { kind, words, untilMs, partner, startMs }
M.actRestUntil = {}

-- the weather / time (shared with Weather.lua); every ClimateManager call guarded
function M.climate()
    local c = { hour = 12, rain = 0, snow = 0, fog = 0, wind = 0, temp = 15, storm = false, season = nil, night = false }
    pcall(function() c.hour = getGameTime():getHour() end)
    local cm = nil
    pcall(function() cm = getClimateManager() end)
    if cm ~= nil then
        local function num(name) local v = nil; pcall(function() if cm[name] then v = cm[name](cm) end end); return tonumber(v) end
        c.rain = num("getRainIntensity") or 0
        c.snow = num("getSnowIntensity") or 0
        c.fog = num("getFogIntensity") or 0
        c.wind = num("getWindIntensity") or 0
        c.temp = num("getTemperature") or 15
        pcall(function() c.storm = cm.getIsThunderStorming and cm:getIsThunderStorming() == true end)
        pcall(function()
            local wp = cm.getWeatherPeriod and cm:getWeatherPeriod() or nil
            if wp ~= nil and wp.isRunning and wp:isRunning() then
                c.period = true
                if (wp.isThunderStorm and wp:isThunderStorm()) or (wp.isTropicalStorm and wp:isTropicalStorm()) or (wp.isBlizzard and wp:isBlizzard()) then c.storm = true end
                if wp.isBlizzard and wp:isBlizzard() then c.blizzard = true end
            end
        end)
        pcall(function() c.season = cm.getSeasonName and tostring(cm:getSeasonName()) or nil end)
    end
    c.night = c.hour >= 22 or c.hour < 6
    return c
end

-- activity catalog: preset = A-Life animation preset id; where = indoors / outdoors / any; seat / bed wanted
M.actCatalog = {
    sleep = { preset = "bed_asleep", alt = "doze_sit", bed = true, ms = 900000, words = "trying to get some sleep", line = { "Gonna get some shut-eye.", "Wake me if anything happens." } },
    rest = { preset = "bed_awake", alt = "sit_wall", bed = true, ms = 420000, words = "lying down for a bit, resting", line = { "Need to lie down a minute.", "Just... resting my eyes." } },
    sit = { preset = "sit_bench", alt = "sit_ground", seat = true, ms = 300000, words = "sitting down, taking a breather", line = { "Feels good to sit.", "Ahh. My feet." } },
    campfire = { preset = "warm_hands", where = "outdoors", ms = 360000, words = "warming up by the fire", line = { "Nothing beats a fire.", "Come warm your hands." } },
    eat = { preset = "eat", ms = 150000, words = "eating something", line = { "Finally, food.", "Not bad. Not good either." } },
    drink = { preset = "drink", ms = 120000, words = "having a drink", line = { "Cheers to still breathing.", "Just one. Maybe two." } },
    smoke = { preset = "smoke", ms = 150000, words = "having a smoke", line = { "Smoke break.", "Don't tell me these'll kill me." } },
    read = { preset = "read", seat = true, ms = 360000, words = "reading", line = { "Found this old book.", "Shh, good part." } },
    watch = { preset = nil, ms = 300000, window = true, words = "keeping watch out the window", line = { "I'll keep an eye out.", "Quiet out there. Too quiet." } },
    guard = { preset = "ready_kneel", ms = 240000, words = "standing guard", line = { "I've got the watch.", "Nobody gets past me." } },
    tinker = { preset = "build_crate", ms = 300000, words = "fixing up some gear", line = { "This thing's held together with tape.", "Almost got it..." } },
    chop = { preset = "chop_wood", where = "outdoors", ms = 300000, words = "chopping firewood", line = { "Winter's coming.", "Good to work the arms." } },
    garden = { preset = "farm_tend", where = "outdoors", ms = 360000, words = "tending the garden", line = { "These might actually grow.", "Weeds everywhere." } },
    clean = { preset = "sit_ground", ms = 200000, words = "cleaning their weapon", line = { "Clean gun, live man.", "Gotta keep it oiled." } },
    pray = { preset = "pray", ms = 180000, words = "praying", line = { "Lord, watch over us.", "...amen." } },
    grieve = { preset = "bow_head", ms = 200000, words = "grieving someone they lost", line = { "I miss you...", "Should've been me." } },
    exercise = { preset = "breathe", ms = 180000, words = "exercising", line = { "Gotta stay in shape.", "Twenty more..." } },
    scavenge = { preset = "search_mid", ms = 200000, words = "looking through stuff for anything useful", line = { "Anything useful in here...", "Junk. Junk. Ooh." } },
    write = { preset = "write", seat = true, ms = 240000, words = "writing in a notebook", line = { "Keeping a journal. Someone should remember.", "Just writing things down." } },
    chat = { preset = "sit_down", ms = 300000, pair = true, words = "chatting with a friend", line = { "Sit with me a while.", "Got a minute?" } },
    cards = { preset = "sit_ground", ms = 360000, pair = true, words = "playing cards", line = { "Deal me in.", "You're cheating, I swear." } },
    pace = { preset = "breathe", ms = 120000, words = "pacing around, too wound up to sit", line = { "Can't sit still.", "Something's not right." } },
    barricade = { preset = "board_up", ms = 120000, care = true, words = "barricading the place", line = { "Let's lock this place down.", "Boards up, lights off." } },
}

-- weights for one NPC right now
function M.actWeights(uid, l, c, ctx)
    local w = {}
    local lens = M.lens and M.lens(uid) or {}
    local p = M.partsOf and M.partsOf(uid) or nil
    local k = p and p.core and p.core.key or ""
    local regs = p and p.bg and tostring(p.bg.regs or "") or ""
    local function add(kind, v) if v > 0 then w[kind] = (w[kind] or 0) + v end end
    local outdoorsOk = not ctx.indoors and c.rain < 0.3 and c.snow < 0.3 and not c.storm
    if c.night then add("sleep", 60); add("watch", 8 + (lens.paranoid or 0) * 30); add("guard", (string.find(regs, "military") or string.find(regs, "law")) and 15 or 3)
    else
        add("sit", 22); add("eat", (c.hour >= 11 and c.hour <= 13 or c.hour >= 18 and c.hour <= 20) and 25 or 4)
        add("read", 4 + (lens.curious or 0) * 15); add("write", 2 + (lens.curious or 0) * 6)
        add("tinker", 5 + ((string.find(regs, "worker") and 12) or 0)); add("clean", 3 + ((string.find(regs, "military") or string.find(regs, "law") or string.find(regs, "outlaw")) and 12 or 0))
        add("exercise", 3 + (lens.disciplined or 0) * 10 + (lens.brave or 0) * 5); add("scavenge", 5 + (lens.greedy or 0) * 10)
        add("watch", 4 + (lens.paranoid or 0) * 20); add("guard", 3 + ((string.find(regs, "military") or string.find(regs, "law")) and 10 or 0))
        if outdoorsOk then add("chop", (c.temp < 10 and 10 or 4) + (lens.disciplined or 0) * 5); add("garden", (c.hour >= 7 and c.hour <= 17) and 6 or 0) end
        if ctx.partner then add("chat", 28 + (lens.cheerful or 0) * 12); add("cards", 12) end
    end
    if not ctx.indoors and (c.night or c.temp < 8) and ctx.camp then add("campfire", 25) end
    add("smoke", (k == "hothead" or k == "bitter" or k == "drifter" or k == "hardass") and 10 or 2)
    add("drink", (k == "hedonist" or k == "sour" or k == "haunted" or k == "depressive") and 8 or 1)
    add("pray", 1 + (lens.devout or 0) * 25)
    if ctx.grief then add("grieve", 15 + ctx.grief * 30) end
    -- mood
    local b = M.emoBehavior and M.emoBehavior(uid) or {}
    if (b.fear or 0) > 0.3 then add("pace", 20 * (b.fear or 0)); add("watch", 10) end
    if (b.low or 0) > 0.4 then add("rest", 15); add("grieve", ctx.grief and 10 or 0) end
    if ctx.hungry then add("eat", 30) end
    -- body
    if ctx.tired then add("rest", 30); add("sleep", 15) end
    if ctx.hurt then add("rest", 25 + ctx.hurt * 40); w.exercise, w.chop, w.scavenge = nil, nil, nil end
    if ctx.drunk then add("rest", 20); add("drink", 6) end
    if k == "depressive" or k == "hopeless" or k == "hollow" then add("rest", 18) end
    -- holed up: barricade first, then furniture, beds at night, lie down
    if ctx.shelter then
        w.chop, w.garden, w.campfire, w.scavenge = nil, nil, nil, nil
        if not ctx.boarded then add("barricade", 80) end
        add("sit", 20); add("watch", 15)
        if c.night then add("sleep", 40) end
    end
    if c.storm or c.rain > 0.5 then w.chop, w.garden = nil, nil end
    return w
end

function M.actContext(uid, l, c)
    local ctx = {}
    local sq = nil
    pcall(function() sq = l.shell:getCurrentSquare() end)
    pcall(function() ctx.indoors = sq ~= nil and (sq:isOutside() == false) end)
    local m = type(l.record.memory) == "table" and l.record.memory or {}
    ctx.camp = m.encounter == "camp" or m.havenId ~= nil
    local P = patch()
    ctx.shelter = m.shelterBuildingId ~= nil or (P and P.data and type(P.data.shelter) == "table" and P.data.shelter[tostring(uid)] ~= nil) or false
    ctx.boarded = M.actBoarded and M.actBoarded[tostring(m.shelterBuildingId or uid)] or false
    if M.woundState then
        local ok, s = pcall(M.woundState, uid, l.shell, l.record)
        if ok and s and s.hurt then ctx.hurt = clamp((s.pain or 0) + (s.limp and 0.2 or 0), 0, 1) end
    end
    if M.drunkOf then local ok, d = pcall(M.drunkOf, uid); if ok and (tonumber(d) or 0) >= 30 then ctx.drunk = true end end
    if M.lifeOf then local ok, life = pcall(M.lifeOf, uid); if ok and type(life) == "table" then
        if (tonumber(life.sleep) or 0) >= 0.6 then ctx.tired = true end
        if (tonumber(life.hunger) or 0) >= 0.6 then ctx.hungry = true end
    end end
    if c.hour >= 1 and c.hour < 5 then ctx.tired = true end
    if M.griefOf then
        local g = M.griefOf(uid)
        local best = 0
        for _, e in pairs(g) do if type(e) == "table" and M.griefIntensity then local ok, i = pcall(M.griefIntensity, e); if ok and tonumber(i) and i > best then best = i end end end
        if best >= 0.2 then ctx.grief = best end
    end
    -- a friend close by and idle (for chat / cards)
    local x, y, z = pos(l.shell)
    for _, o in ipairs(M.nearbyNpcs and x and M.nearbyNpcs(x, y, z, 8, uid) or {}) do
        local ou = tostring(o.record.uid)
        if not M.activities[ou] and M.closeness and select(1, M.closeness(uid, ou)) >= 0.3 then ctx.partner = o; break end
    end
    return ctx
end

-- seat (A-Life SeatApi), bed (sprite), window (IsoWindow) near the NPC
local function squaresAround(x, y, z, r, visit)
    local cell = getCell and getCell() or nil
    if cell == nil then return end
    for dx = -r, r do
        for dy = -r, r do
            local sq = nil
            pcall(function() sq = cell:getGridSquare(math.floor(x) + dx, math.floor(y) + dy, math.floor(z or 0)) end)
            if sq ~= nil and visit(sq, dx * dx + dy * dy) then return end
        end
    end
end
function M.findSeatNear(l, now)
    local pa = PA()
    if not fn(pa and pa.SeatApi, "at") then return nil end
    local x, y, z = pos(l.shell)
    local best, bd = nil, 1e9
    squaresAround(x, y, z, M.actCfg.seatTiles, function(sq, d2)
        if d2 < bd then
            local ok, seat = pcall(pa.SeatApi.at, l.shell, sq:getX(), sq:getY(), sq:getZ(), now, { x = x, y = y, z = z })
            if ok and type(seat) == "table" then best, bd = seat, d2 end
        end
        return false
    end)
    return best
end
function M.findBedNear(l)
    local x, y, z = pos(l.shell)
    local best, bd = nil, 1e9
    squaresAround(x, y, z, M.actCfg.bedTiles, function(sq, d2)
        if d2 < bd then
            local objs = nil
            pcall(function() objs = sq:getObjects() end)
            local n = 0
            pcall(function() n = objs:size() end)
            for i = 0, n - 1 do
                local name = ""
                pcall(function() name = tostring(objs:get(i):getSprite():getName() or "") end)
                if string.find(name, "bedding", 1, true) or string.find(string.lower(name), "_bed", 1, true) then
                    best, bd = { x = sq:getX(), y = sq:getY(), z = sq:getZ() }, d2
                    break
                end
            end
        end
        return false
    end)
    return best
end
function M.findWindowNear(l)
    local x, y, z = pos(l.shell)
    local best, bd = nil, 1e9
    squaresAround(x, y, z, 7, function(sq, d2)
        if d2 < bd then
            local w = nil
            pcall(function() w = sq:getWindow() end)
            if w ~= nil then best, bd = { x = sq:getX(), y = sq:getY(), z = sq:getZ() }, d2 end
        end
        return false
    end)
    return best
end

M.actBoarded = {}
function M.startActivity(l, kind, now, opts)
    opts = opts or {}
    local P = patch()
    local def = M.actCatalog[kind]
    if P == nil or not fn(P, "activityStart") or def == nil then return false, "no_patch" end
    local uid = tostring(l.record.uid)
    local spec = { kind = kind, ms = def.ms, preset = def.preset }
    if def.bed then
        local bed = M.findBedNear(l)
        if bed then spec.anchor = bed else spec.preset = def.alt or spec.preset end
    elseif def.seat then
        local seat = M.findSeatNear(l, now)
        if seat then
            spec.anchor = { x = seat.sx or math.floor(seat.x), y = seat.sy or math.floor(seat.y), z = seat.z or 0 }
            spec.seat = seat
            pcall(PA().SeatApi.claim, seat, l.shell, now)
        else spec.preset = def.alt or "sit_ground" end
    elseif def.window then
        local w = M.findWindowNear(l)
        if w then spec.anchor = w end
    end
    if def.care then
        local c = M.climate()
        spec.care = { night = c.night, board = true }
        local m = type(l.record.memory) == "table" and l.record.memory or {}
        M.actBoarded[tostring(m.shelterBuildingId or uid)] = true
    end
    if fn(PA().Animations, "presetOf") and spec.preset and PA().Animations.presetOf(spec.preset) == nil then
        spec.preset = def.alt or nil -- this A-Life build doesn't have it
    end
    spec.player = ALifeSide.you()
    local ok, why = P.activityStart(uid, spec)
    if not ok then skipped(uid, kind .. " refused by the patch: " .. tostring(why)); return false, why end
    M.actStats.started = M.actStats.started + 1
    M.actLog("started " .. actName(uid) .. ": " .. kind .. " (" .. (spec.seat and "on a seat" or (def.bed and spec.anchor and "in a bed")
        or (def.window and spec.anchor and "at a window") or (spec.anchor and "at a spot") or "right here") .. ", pose "
        .. tostring(spec.preset or "none") .. ", " .. math.floor(def.ms / 60000) .. " min, "
        .. (why == "owned" and "patch drives them (A-Life step paused)" or "A-Life hold order") .. ")")
    M.activities[uid] = { kind = kind, words = def.words, untilMs = now + def.ms, startMs = now, partner = opts.partner }
    if M.logInteraction and (hash(uid .. kind .. math.floor(now / 3600000)) % 4 == 0) then pcall(M.logInteraction, uid, "Started " .. def.words, nil, nil, "event") end
    -- an ambient line now and then
    if def.line and (hash(uid .. now) % 100) < 22 and M.say then
        local player = ALifeSide.you()
        M.say(l.shell, player, pick(def.line, uid .. now), { record = l.record })
    end
    log("activity: " .. uid .. " -> " .. kind .. (spec.anchor and " (anchor)" or ""))
    return true
end

function M.pickActivity(uid, l, c, ctx, now)
    local w = M.actWeights(uid, l, c, ctx)
    local total = 0
    for _, v in pairs(w) do total = total + v end
    if total <= 0 then return nil end
    local r = (M.actRoll and M.actRoll(uid, total)) or (hash(uid .. "#act#" .. math.floor(now / 60000)) % math.max(1, math.floor(total)))
    local keys = {}
    for kk in pairs(w) do keys[#keys + 1] = kk end
    table.sort(keys)
    for _, kk in ipairs(keys) do
        if r < w[kk] then return kk end
        r = r - w[kk]
    end
    return keys[#keys]
end

-- patch 1.4 step / end events -> log lines
function M.actHook()
    local P = patch()
    if M.actHooked or P == nil or type(P.hooks) ~= "table" or type(P.hooks.activityEnd) ~= "table" then return end
    M.actHooked = true
    if type(P.hooks.activityStep) == "table" then
        table.insert(P.hooks.activityStep, function(uid, step, kind, info)
            if step == "reasserted" then M.actStats.reasserted = M.actStats.reasserted + 1 end
            M.actLog(tostring(step) .. " " .. actName(uid) .. ": " .. tostring(kind) .. (info and (" - " .. tostring(info)) or ""),
                step == "reasserted" and ("re|" .. tostring(uid)) or nil, 30000)
        end)
    end
    table.insert(P.hooks.activityEnd, function(uid, kind, why)
        local done = why == "done"
        if done then M.actStats.finished = M.actStats.finished + 1 else M.actStats.interrupted = M.actStats.interrupted + 1 end
        M.actLog((done and "finished " or "interrupted ") .. actName(uid) .. ": " .. tostring(kind) .. (done and "" or (" - " .. tostring(why))))
    end)
end
function M.actSummary(now)
    local st = M.actStats
    local n, kinds = 0, {}
    for _, a in pairs(M.activities) do n = n + 1; kinds[a.kind] = (kinds[a.kind] or 0) + 1 end
    if n == 0 and st.chosen + st.started + st.interrupted + st.finished + st.skipped == 0 then return nil end
    local ks = {}
    for k, v in pairs(kinds) do ks[#ks + 1] = k .. " " .. v end
    table.sort(ks)
    local ws = {}
    for k, v in pairs(st.why) do ws[#ws + 1] = { k = k, v = v } end
    table.sort(ws, function(a, b) if a.v ~= b.v then return a.v > b.v end return a.k < b.k end)
    local wl = {}
    for i = 1, math.min(3, #ws) do wl[#wl + 1] = ws[i].k .. " x" .. ws[i].v end
    local P = patch()
    local line = "summary: " .. n .. " doing something" .. (#ks > 0 and (" (" .. table.concat(ks, ", ") .. ")") or "")
        .. "; last minute: chosen " .. st.chosen .. ", started " .. st.started .. ", reasserted " .. st.reasserted
        .. ", finished " .. st.finished .. ", interrupted " .. st.interrupted .. ", skipped " .. st.skipped
        .. (#wl > 0 and (" (" .. table.concat(wl, "; ") .. ")") or "")
        .. ((P and fn(P, "ownSummary")) and (" | patch " .. P.ownSummary()) or "")
    M.actStats = { chosen = 0, started = 0, reasserted = 0, interrupted = 0, finished = 0, skipped = 0, why = {} }
    M.actLog(line)
    return line
end
function M.activityTick(now)
    if M.settings.activity == false or not M.worldHere() then return end
    local P = patch()
    if P == nil or not fn(P, "activityStart") then return end
    if not M.actHooked then pcall(M.actHook) end
    if now - (M.actSummaryAt or now) >= (M.actCfg.summaryMs or 60000) then M.actSummaryAt = now; pcall(M.actSummary, now) end
    M.actSummaryAt = M.actSummaryAt or now
    -- drop finished ones (the patch ended them)
    local live = 0
    for uid, a in pairs(M.activities) do
        if type(P.acts) == "table" and P.acts[uid] == nil then
            M.activities[uid] = nil
            M.actRestUntil[uid] = now + M.actCfg.restMs
        else
            live = live + 1
            if a.partner and a.kind == "chat" and now - (a.bondAt or a.startMs) >= 120000 and M.pairBump then
                a.bondAt = now
                pcall(M.pairBump, uid, tostring(a.partner), 1, "sat and talked")
            end
        end
    end
    if live >= M.actCfg.maxActive then return end
    local player = ALifeSide.you()
    if ALifeSide.mpServer() then -- pre-1.0 MP: one online player per tick, in turn (people near them pick something to do)
        local list = ALifeSide.online()
        if #list == 0 then return end
        M._actTurn = ((M._actTurn or 0) % #list) + 1
        player = list[M._actTurn]
        local okW, res = ALifeSide.with(player, M.activityTickFor, now, player)
        if not okW then error(res) end
        return res
    end
    return M.activityTickFor(now, player)
end
function M.activityTickFor(now, player)
    if player == nil then return end
    local x, y, z = pos(player)
    local c = M.climate()
    local started = 0
    local pa = PA()
    for _, l in ipairs(M.nearbyNpcs and M.nearbyNpcs(x, y, z, M.actCfg.tiles) or {}) do
        if started >= M.actCfg.perTick then break end
        local uid = tostring(l.record.uid)
        local m = type(l.record.memory) == "table" and l.record.memory or {}
        -- why NOT (first reason wins; logged rate-limited). Talk.busy stays: it means fighting / fleeing / retreating /
        -- recovering endurance - NOT plain walking (the user's edit removed it on that assumption).
        local whyNot = nil
        if M.activities[uid] then whyNot = "already busy with " .. tostring(M.activities[uid].kind)
        elseif now < (M.actRestUntil[uid] or 0) then whyNot = nil -- resting between activities: normal, not logged
        elseif M.isPaused and M.isPaused(uid) then whyNot = "paused (listening)"
        elseif m.orderedTo ~= nil then whyNot = "has an order (" .. tostring(type(m.orderedTo) == "table" and m.orderedTo.kind or m.orderedTo) .. ")"
        elseif fn(pa.Talk, "busy") and pa.Talk.busy(l.record, now) then whyNot = "fighting / fleeing"
        elseif M.inCombat and M.inCombat(l.shell, l.record) then whyNot = "in combat"
        elseif M.terr and M.terr.speaker == uid then whyNot = "warning you off"
        elseif fn(P, "companionOf") and P.companionOf(uid) then whyNot = "companion"
        elseif M.bucket and M.bucket("party")[uid] then whyNot = "in your party"
        elseif M.withPlayer and M.withPlayer(uid, player) then whyNot = "walking with you" -- 0.6.12: said yes to follow = follows
        elseif (function() local v = nil; pcall(function() v = l.shell and l.shell:getVehicle() end); return v ~= nil end)() then whyNot = "in a vehicle" -- 0.6.12
        elseif fn(P, "owner") and (P.owner(uid) == "listen" or P.owner(uid) == "party") then whyNot = "listening / with you"
        elseif fn(pa.Talk, "stance") and pa.Talk.stance(l.record, player) == "hostile" then whyNot = "hostile to you" end
        local idle = whyNot == nil and not M.activities[uid] and now >= (M.actRestUntil[uid] or 0)
        if whyNot ~= nil and not M.activities[uid] then skipped(uid, whyNot) end
        if idle then
            local ctx = M.actContext(uid, l, c)
            local kind = M.pickActivity(uid, l, c, ctx, now)
            if kind then
                M.actStats.chosen = M.actStats.chosen + 1
                local w = M.actWeights(uid, l, c, ctx)
                local top = {}
                for k2, v2 in pairs(w) do top[#top + 1] = { k = k2, v = v2 } end
                table.sort(top, function(a2, b2) if a2.v ~= b2.v then return a2.v > b2.v end return a2.k < b2.k end)
                local tops = {}
                for i2 = 1, math.min(4, #top) do tops[#tops + 1] = top[i2].k .. " " .. math.floor(top[i2].v) end
                M.actLog("chosen " .. actName(uid) .. ": " .. kind .. " (top: " .. table.concat(tops, ", ") .. ")")
                local def = M.actCatalog[kind]
                local partner = def and def.pair and ctx.partner or nil
                if def and def.pair and partner == nil then kind = "sit" end
                local ok = M.startActivity(l, kind, now, { partner = partner and tostring(partner.record.uid) or nil })
                if ok then
                    started = started + 1
                    if partner then
                        local ok2 = M.startActivity(partner, kind, now, { partner = uid })
                        if not ok2 then M.activities[uid].partner = tostring(partner.record.uid) end
                    end
                else M.actRestUntil[uid] = now + 30000 end
            end
        end
    end
end

function M.activityOf(uid)
    local a = M.activities[tostring(uid)]
    if a == nil then return nil end
    return a
end
function M.activityLine(uid)
    local a = M.activityOf(uid)
    if a == nil then return nil end
    local who = ""
    if a.partner then
        local r = PA() and PA().ActorRegistry and PA().ActorRegistry.read(tostring(a.partner)) or nil
        if r and M.shownName and getPlayer then who = " with " .. tostring(select(1, M.shownName(a.partner, ALifeSide.you()))) end
    end
    return a.words .. who
end

-- pre-1.0 (Joe Nov 20: "npcs have weird animations, asking 'what are you doing' should tell what they're working on"):
-- the answer is what they are really on right now, first match wins: lying hurt, their camp job, your order, our idle
-- activity, then A-Life's own activity / intent (the words its squad map uses). nil = nothing we can name.
M.doingOrders = { follow = "keeping up, following", hold = "holding this spot like I was told", surrender = "keeping my hands where you can see them",
    leave = "leaving, like you said", flee = "getting out of here" }
function M.doingNow(uid, l, player)
    uid = tostring(uid)
    local record = type(l) == "table" and l.record or nil
    local shell = type(l) == "table" and l.shell or nil
    local pa = PA()
    if record == nil and pa and pa.ActorRegistry and fn(pa.ActorRegistry, "read") then record = pa.ActorRegistry.read(uid) end
    if shell == nil and pa and fn(pa.Talk, "shellFor") then pcall(function() shell = pa.Talk.shellFor(uid) end) end
    -- lying hurt (A-Life's injury system): the pose people asked about
    local downed = false
    pcall(function() local md = shell:getModData(); downed = md.ProjectALifeInjured == "down" or md.ProjectALifeInjured == "dragged" end)
    if downed then return "lying here hurt - I can't get up" end
    -- the camp job you gave them (Camp > Roles / jobs)
    if type(M.cpJobs) == "table" and type(M.cpJobs[uid]) == "table" then
        if fn(M, "bdDoing") then local ok, w = pcall(M.bdDoing, uid, player); if ok and type(w) == "string" and w ~= "free" then return w end end
        return tostring(M.cpJobs[uid].kind or "work") .. " work for the camp"
    end
    -- your order
    local mem = type(record) == "table" and type(record.memory) == "table" and record.memory or {}
    if mem.orderedTo ~= nil then
        local kind = type(mem.orderedTo) == "table" and mem.orderedTo.kind or mem.orderedTo
        return M.doingOrders[tostring(kind)] or ("doing what you told me (" .. string.gsub(tostring(kind), "_", " ") .. ")")
    end
    -- our idle activity (sitting, chatting, smoking, ...)
    local line = M.activityLine(uid)
    if line then return line end
    -- A-Life's own activity / intent, in the words of its squad map (client file; plain words without it)
    local raw = type(record) == "table" and record.activity or nil
    if type(raw) == "string" and raw ~= "" and raw ~= "idle" and raw ~= "dead" then
        local Tip = pa and pa.SquadMapTooltip or nil
        if fn(Tip, "activity") then
            local ok, words = pcall(Tip.activity, raw)
            if ok and type(words) == "string" and words ~= "" then return string.lower(words) end
        end
        local base = string.match(raw, "^(.-) %(") or raw
        return (string.gsub(string.gsub(base, "_", " "), "%s%d+$", ""))
    end
    return nil
end
-- "what are you doing?" - accurate (the AI gets req.activity; a stock answer when there's no bridge)
M.whatDoingWords = { "what are you doing", "what you doing", "whatcha doing", "what are you up to", "what you up to", "watcha doin",
    "what're you doing", "what are you working on", "what you working on" }
function M.onWhatDoing(player, text, loud, hearers)
    local low = string.lower(tostring(text or ""))
    local hit = false
    for _, w in ipairs(M.whatDoingWords) do if string.find(low, w, 1, true) then hit = true end end
    if not hit or hearers == nil or hearers[1] == nil then return end
    local l = hearers[1]
    local uid = tostring(l.record.uid)
    local okD, line = pcall(M.doingNow, uid, l, player)
    if not okD then line = M.activityLine(uid) end
    M.askedWhatDoing = { uid = uid, at = nowMs(), words = line }
    if not (M.bridgeAlive and M.bridgeAlive(nowMs())) and M.say then
        M.say(l.shell, player, line and ("Just " .. line .. ".") or "Nothing much. Keeping my eyes open.", { record = l.record })
    end
end
table.insert(M.playerWordHooks, M.onWhatDoing)

table.insert(M.requestExtras, function(req, player, listener, now)
    local uid = tostring(listener.record.uid)
    local okD, line = pcall(M.doingNow, uid, listener, player)
    if not okD then line = M.activityLine(uid) end
    if line then req.activity = { now = line } end
    local asked = M.askedWhatDoing
    if asked and asked.uid == uid and now - asked.at < 8000 then req.activity = req.activity or {}; req.activity.asked = true end
end)

if type(Events) == "table" and Events.OnTick then
    local last = -1e12
    ALifeHealth.tickAdd("ALifeLLMTalk_Activity", function()
        local now = nowMs()
        if now - last < M.actCfg.tickMs then return end
        last = now
        local ok, e = pcall(M.activityTick, now)
        if not ok then log("activity error: " .. tostring(e)) end
    end)
end

return M
