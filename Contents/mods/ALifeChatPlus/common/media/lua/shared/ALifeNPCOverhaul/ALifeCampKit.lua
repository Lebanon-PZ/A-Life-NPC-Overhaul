-- A-Life NPC Overhaul pre-1.0: CAMP KIT. Small shared helpers for the camp-life modules from docs/PLAN-RIM.md
-- (breaks, inspirations, job likes, keep stocked, stockpiles, areas, beds, schedule, known worth, fistfights).
-- Everything here sits on the real camp (ALifeTalk_Camp): its people (M.cpPeople), the daily unrest (store.unrest,
-- 0-100, positive = worse, ALifeLLMTalk_Dynamics), the job loop (M.cpAddJob), the mood hooks (M.cpMoraleHooks), the
-- camp menu (M.cpMenus) and the AI extras (M.cpExtras). No game calls at load.
require "ALifeNPCOverhaul/AA_Side"
ALifeCampKit = ALifeCampKit or {}
local K = ALifeCampKit
K.VERSION = "pre-1.0"
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
K.fn = fn
function K.M() return type(ALifeLLMTalk) == "table" and ALifeLLMTalk or nil end
function K.PA() return type(ProjectALife) == "table" and ProjectALife or {} end
function K.log(tag, msg) print(tostring(tag) .. " " .. tostring(msg)) end
function K.hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
function K.hourOfDay()
    local h = nil
    pcall(function() h = getGameTime():getHour() end)
    return tonumber(h) or (math.floor(K.hours()) % 24)
end
function K.day() return math.floor(K.hours() / 24) end
function K.hash(s) local h = 5381; s = tostring(s); for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end; return h end
-- one roll 0..1 (tests replace K.rnd)
function K.rnd() return math.random() end
function K.chance(pct) return K.rnd() * 100 < (tonumber(pct) or 0) end
function K.clamp(v, a, b) if v < a then return a end; if v > b then return b end; return v end
function K.pos(o) if o == nil then return nil end; local x, y, z = nil, nil, nil; pcall(function() x, y, z = o:getX(), o:getY(), o:getZ() end); return x, y, z end
function K.d2(ax, ay, bx, by) return (ax - bx) ^ 2 + (ay - by) ^ 2 end
-- pre-1.0 MP (P4): the camp's player. SP: you. MP server: the player whose base it is (Main's M.homePlayer)
function K.player()
    local M = K.M()
    if ALifeSide.mpServer() and M and fn(M, "homePlayer") then return M.homePlayer() end
    return ALifeSide.localPlayer()
end

-- settings: defaults into ALifeLLMTalk.settings + fileKeys at LOAD (CLAUDE.md rule 2), rows for the Settings page
function K.reg(defaults, rows, cat)
    local M = ALifeLLMTalk
    if type(M) ~= "table" then return end
    M.settings = type(M.settings) == "table" and M.settings or {}
    M.fileKeys = type(M.fileKeys) == "table" and M.fileKeys or {}
    local have = {}
    for _, x in ipairs(M.fileKeys) do have[x] = true end
    for k, v in pairs(defaults) do
        if M.settings[k] == nil then M.settings[k] = v end
        if not have[k] then M.fileKeys[#M.fileKeys + 1] = k; have[k] = true end
    end
    if type(rows) == "table" then
        M.settingRows = type(M.settingRows) == "table" and M.settingRows or {}
        local hr = {}
        for _, r in ipairs(M.settingRows) do hr[r[1]] = true end
        for _, r in ipairs(rows) do if not hr[r[1]] then M.settingRows[#M.settingRows + 1] = r; hr[r[1]] = true end end
    end
    if cat ~= nil then
        M.settingCatOf = type(M.settingCatOf) == "table" and M.settingCatOf or {}
        for k in pairs(defaults) do if M.settingCatOf[k] == nil then M.settingCatOf[k] = cat end end
    end
end
-- explicit nil check (a false setting stays false)
function K.set(defaults, key)
    local M = ALifeLLMTalk
    local v = nil
    if type(M) == "table" and type(M.settings) == "table" then v = M.settings[key] end
    if v == nil then v = defaults[key] end
    return v
end
function K.num(defaults, key) local v = tonumber(K.set(defaults, key)); if v == nil then v = tonumber(defaults[key]) or 0 end; return v end

-- saved state: one bucket per module in our world ModData (M.bucket)
-- pre-1.0 MP (P4): an MP client reads a camp-life bucket from the camp copy the server shares (read-only; menu writes
-- go through K.run -> M.cpAct on the server). Every bucket used on the server is listed for that copy.
function K.bucket(name)
    local M = K.M()
    if ALifeSide.mpClient() and M and fn(M, "cpView") then
        local v = M.cpView()
        local b = v and type(v.buckets) == "table" and v.buckets[name] or nil
        if type(b) == "table" then return b end
        K.tmp = K.tmp or {}
        K.tmp[name] = K.tmp[name] or {}
        return K.tmp[name]
    end
    if M then M.cpShareBuckets = M.cpShareBuckets or {}; M.cpShareBuckets[name] = true end
    if M and fn(M, "bucket") then return M.bucket(name) end
    K.tmp = K.tmp or {}
    K.tmp[name] = K.tmp[name] or {}
    return K.tmp[name]
end

-- people
function K.rec(uid) local r = nil; pcall(function() r = K.PA().ActorRegistry.read(tostring(uid)) end); return r end
function K.shell(uid) local s = nil; pcall(function() s = K.PA().Talk.shellFor(tostring(uid)) end); return s end
function K.first(uid)
    local r = K.rec(uid)
    local m = r and type(r.memory) == "table" and r.memory or {}
    if type(m.personFirst) == "string" and m.personFirst ~= "" then return m.personFirst end
    local n = nil
    pcall(function() n = K.PA().Names.of(r) end)
    if type(n) == "string" and n ~= "" then return string.match(n, "^(%S+)") or n end
    if r and type(r.name) == "string" and r.name ~= "" then return string.match(r.name, "^(%S+)") or r.name end
    return "Someone"
end
function K.lens(uid) local l = {}; local M = K.M(); if M and fn(M, "lens") then pcall(function() l = M.lens(tostring(uid)) or {} end) end; return l end
function K.people(player)
    local M = K.M()
    if M == nil or not fn(M, "cpPeople") or player == nil then return {} end
    local ok, list = pcall(M.cpPeople, player)
    return ok and type(list) == "table" and list or {}
end
function K.home(uid, player) local M = K.M(); if M == nil or not fn(M, "cpIsHome") then return false end; local ok, y = pcall(M.cpIsHome, uid, player); return ok and y == true end
function K.roleOf(uid) local M = K.M(); if M and fn(M, "cpRoleOf") then local ok, r = pcall(M.cpRoleOf, uid); if ok then return r end end; return "general" end
function K.base(player) local M = K.M(); if M and fn(M, "wzBase") then local ok, b = pcall(M.wzBase, player); if ok then return b end end; return nil end
function K.inBase(b, x, y) return b ~= nil and x ~= nil and tonumber(b.x1) ~= nil and x >= b.x1 and x <= b.x2 and y >= b.y1 and y <= b.y2 end

-- the daily unrest (ALifeLLMTalk_Dynamics.dynUnrest): 0..100, positive = worse
function K.unrestRow(uid)
    local M = K.M()
    local st = M and fn(M, "store") and M.store() or nil
    if type(st) ~= "table" then return nil end
    st.unrest = type(st.unrest) == "table" and st.unrest or {}
    local u = st.unrest[tostring(uid)]
    if type(u) ~= "table" then u = { v = 0 }; st.unrest[tostring(uid)] = u end
    return u
end
function K.unrest(uid) local u = K.unrestRow(uid); return u and (tonumber(u.v) or 0) or 0 end
function K.addUnrest(uid, d)
    local u = K.unrestRow(uid)
    if u == nil then return 0 end
    u.v = K.clamp((tonumber(u.v) or 0) + (tonumber(d) or 0), 0, 100)
    return u.v
end

-- out loud / letters / cards / memory / chronicle
function K.say(uid, line)
    if line == nil then return false end
    local sh = K.shell(uid)
    if sh == nil then return false end
    local ok, res = pcall(function() return K.PA().Speech.say(sh, line, {}) end)
    return ok and res ~= false
end
function K.letter(text, r, g, b)
    if ALifeSide.mpServer() then -- MP: to the player being handled, else everyone online
        if type(ALifeOut) ~= "table" then return false end
        return ALifeOut.letter(ALifeSide.cur, tostring(text), r or 220, g or 200, b or 150) > 0
    end
    local p = K.player()
    if p == nil or type(ALifeLetter) ~= "function" then return false end
    return pcall(ALifeLetter, p, tostring(text), r or 220, g or 200, b or 150)
end
function K.card(card, player) local M = K.M(); if M and ALifeSide.mpServer() and fn(M, "outCard") then local ok, r = pcall(ALifeSide.outCard, player or K.player(), card); return ok and r end; if M and fn(M, "momCard") then local ok, r = pcall(M.momCard, card); return ok and r end; return false end
function K.mem(uid, text) local M = K.M(); if M and fn(M, "keyMem") then pcall(M.keyMem, uid, "occasion", text) end end
function K.hist(uid, text) local M = K.M(); if M and fn(M, "histAdd") then pcall(M.histAdd, uid, "party", text) end end
function K.chron(what, who) if fn(ALifeChronicle, "add") then pcall(ALifeChronicle.add, { k = "other", who = who, what = what }) end end
function K.campLog(kind, text) local M = K.M(); if M and fn(M, "cpLog") then pcall(M.cpLog, kind, text) end end
function K.anim(uid, id) local sh = K.shell(uid); local A = K.PA().Animations; if sh and fn(A, "apply") then pcall(A.apply, sh, id) end end
function K.pairS(a, b)
    local M = K.M()
    if M == nil or not fn(M, "pairRow") then return 0 end
    local ok, row = pcall(M.pairRow, tostring(a), tostring(b), true)
    return ok and type(row) == "table" and (tonumber(row.s) or 0) or 0
end
function K.pairBump(a, b, d, why) local M = K.M(); if M and fn(M, "pairBump") then pcall(M.pairBump, tostring(a), tostring(b), d, why) end end
function K.opinion(uid, player, d, why) pcall(function() K.PA().NpcOpinion.adjust(K.rec(uid), player, d, why) end) end

-- camp plug-ins (each list is created by whoever comes first; ALifeTalk_Camp reads them every time)
function K.addMood(f) local M = K.M(); if M == nil then return end; M.cpMoraleHooks = M.cpMoraleHooks or {}; table.insert(M.cpMoraleHooks, f) end
function K.addMenu(f) local M = K.M(); if M == nil then return end; M.cpMenus = M.cpMenus or {}; table.insert(M.cpMenus, f) end
function K.addExtra(f) local M = K.M(); if M == nil then return end; M.cpExtras = M.cpExtras or {}; table.insert(M.cpExtras, f) end
-- pre-1.0 MP (P4): a camp menu write. K.act(kind, f(player, a, b, c, d, e)) registers it; K.run(kind, player, ...)
-- runs it (SP directly; MP client -> the server as the sender, via M.cpAct). f returns false when nothing changed.
function K.act(kind, f) local M = K.M(); if M == nil then return end; M.cpActs = M.cpActs or {}; M.cpActs[kind] = f end
function K.run(kind, player, a, b, c, d, e)
    local M = K.M()
    if M and fn(M, "cpAct") then return M.cpAct(kind, a, b, c, d, e, player) end
    local f = M and type(M.cpActs) == "table" and M.cpActs[kind] or nil
    if type(f) == "function" then return f(player, a, b, c, d, e) end
    return false
end
function K.cnum(v) v = tonumber(v); if v == nil then return nil end; return math.floor(v) end
function K.addJob(def) local M = K.M(); if M and fn(M, "cpAddJob") then M.cpAddJob(def); return true end; return false end

-- wrap t[name] once per function object: chained wraps made later at load are caught again at OnGameStart
-- (gotchas 0.9.5). make(orig) -> new function.
-- Every wrapper we make remembers { tag, orig }: walking down from t[name] finds ours even under someone else's
-- later wrap of a wrap of ours (then it's left alone). Someone else's wrap we can't see through ends the walk.
K.wrapped = K.wrapped or {}
K.chain = K.chain or {}
function K.isWrapped(f, tag)
    local seen = 0
    while type(f) == "function" and seen < 50 do
        local c = K.chain[f]
        if c == nil then return false end
        if c.tag == tag then return true end
        f = c.orig
        seen = seen + 1
    end
    return false
end
-- And a busy flag per tag: if a second copy of ours ever sits in the chain (someone re-wrapped over it unseen), the
-- inner copy passes straight through, so the effect never applies twice. An error in ours falls back to the original.
K.busy = K.busy or {}
local function packn(...) return { n = select("#", ...), ... } end
function K.wrap(t, name, tag, make)
    if type(t) ~= "table" or type(t[name]) ~= "function" then return false end
    if K.isWrapped(t[name], tag) then return true end
    local orig = t[name]
    local inner = make(orig)
    if type(inner) ~= "function" then return false end
    local w = function(...)
        if K.busy[tag] then return orig(...) end
        K.busy[tag] = true
        local r = packn(pcall(inner, ...))
        K.busy[tag] = nil
        if not r[1] then
            if not K.dead[tag] then K.dead[tag] = true; K.log("[ALifeCampKit]", tag .. " wrap error (falls back to the original): " .. tostring(r[2])) end
            return orig(...)
        end
        return unpack(r, 2, r.n)
    end
    t[name] = w
    K.wrapped[tag] = w
    K.chain[w] = { tag = tag, orig = orig }
    return true
end

-- one hourly beat for every module (guarded per module: an error switches only that one off)
K.hourlies = K.hourlies or {}
K.dead = K.dead or {}
function K.hourly(tag, f) K.hourlies[#K.hourlies + 1] = { tag = tag, f = f } end
K.lastHour = K.lastHour or -1
function K.beat()
    local h = math.floor(K.hours())
    if h == K.lastHour then return 0 end
    K.lastHour = h
    local p = K.player()
    local n = 0
    for _, e in ipairs(K.hourlies) do
        if not K.dead[e.tag] then
            local ok, err = pcall(e.f, p, h)
            if ok then n = n + 1 else K.dead[e.tag] = true; K.log(e.tag, "hourly error, off for this session: " .. tostring(err)) end
        end
    end
    return n
end
local Events = ALifeSide.hooks("world", "ALifeCampKit")
if type(Events) == "table" and Events.EveryTenMinutes ~= nil then Events.EveryTenMinutes.Add(function() pcall(K.beat) end) end
return K
