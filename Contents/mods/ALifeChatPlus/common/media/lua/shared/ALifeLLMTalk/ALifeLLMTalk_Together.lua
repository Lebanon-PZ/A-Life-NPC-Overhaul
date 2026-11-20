-- A-Life Talk 0.5.2.10 [pt270u]: PARTNERS SHARE A PAST. "these two are together but having nothing bout eachothers
-- past ... if he has a daughter it should be hers too". Each person's backstory was written alone, so Viola (39,
-- hairdresser, V's Styles, Valley Station, lost her family at the church shelter, weeks in its basement) and Josh
-- (20, college student / trucker from Muldraugh, lost his daughter Emily in the evacuation, walked the tracks)
-- never mentioned each other. Now every partner pair (our Pairs seeding, partners who got together later) gets ONE
-- shared history, made once, deterministic from both uids and both stories, saved for both:
--   * before or after the outbreak: "together since before" pairs whose ages fit (both 22+, at most 15 years apart)
--     met before; everyone else met after (a shelter / basement / the road from their stories).
--   * a lost child: met before and together long enough -> the child is THEIRS (both grieve, both hope to find
--     her); met after -> it stays the parent's child and the partner knows, cares and helps look.
--   * conflicts: before + "lost the whole family" means parents and siblings (the partner made it with them).
--   * a late partner of either (Jorge) is part of it: how the three came together, and that both grieve him.
-- Shown as "Together" in the Overview (under their past) and sent as req.together -> the bridge's never-cut
-- together_core. The Romance line no longer says "Heartbroken" forever while they have a living partner: it says
-- "With Josh; grieving Jorge" and the old feelings for you show only while they are fresh (72 h).
-- Data: ModData bucket "together" = { [pairKey] = { era, years, metDay, met, child, fix, sig } }. Made on first
-- use and once for every existing partner pair on load. Setting: sharedPast.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_Together") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Together"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Together") end end
local M = ALifeLLMTalk
if type(M) ~= "table" then return end
local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, name) return type(t) == "table" and type(t[name]) == "function" end
local function log(msg) M.log(msg) end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end
local function hash(s) local h = 5381; s = tostring(s); for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end; return h end
local function bucket(name) return M.bucket(name) end
local function rec(uid) local pa = PA(); return pa and fn(pa.ActorRegistry, "read") and pa.ActorRegistry.read(tostring(uid)) or nil end
local function nameOf(uid)
    local pa, r = PA(), rec(uid)
    local n = nil
    if r and fn(pa and pa.Names, "of") then pcall(function() n = pa.Names.of(r) end) end
    if n == nil then local e = bucket("book")[tostring(uid)]; n = type(e) == "table" and e.name or nil end
    return tostring(n or "someone")
end
local function firstOf(name) return string.match(tostring(name), "^(%S+)") or tostring(name) end
local function isDead(uid)
    local r = rec(uid)
    if type(r) == "table" and r.lifecycle == "dead" then return true end
    if M.isPersonDead then local ok, d = pcall(M.isPersonDead, uid); if ok and d then return true end end
    return false
end

M.togetherCfg = { beforeMinAge = 22, beforeMaxGap = 15 }
M.towns = { "Valley Station", "West Point", "March Ridge", "Fallas Lake", "Echo Creek", "Muldraugh", "Riverside", "Rosewood",
    "Louisville", "Ekron", "Irvington", "Brandenburg", "Crossroads", "Lexington", "Elizabethtown" }

function M.storyText(uid)
    local row = nil
    if M.personaOf then pcall(function() row = M.personaOf(uid) end) end
    local bits = (row and M.storyBits) and M.storyBits(row) or {}
    return table.concat(bits, " "), bits
end

-- what a story says (plain matching; the LLM wrote it freely)
function M.storyFacts(text)
    local t = tostring(text or "")
    local low = string.lower(t)
    local f = {}
    for _, w in ipairs({ "daughter", "son", "little girl", "little boy", "baby", "kid", "child" }) do
        local i = string.find(low, w, 1, true)
        if i and not (w == "son" and string.find(low, "person", 1, true) == i - 3) then
            local after = string.sub(t, i + #w, i + #w + 24)
            local nm = string.match(after, "^,?%s+(%u%l+)")
            if nm == "And" or nm == "The" or nm == "In" or nm == "When" or nm == "Who" or nm == "During" then nm = nil end
            f.child = { word = (w == "little girl" and "daughter") or (w == "little boy" and "son") or w, name = nm }
            if string.find(string.sub(low, math.max(1, i - 40), i), "lost", 1, true) or string.find(low, "lost", 1, true) then f.child.lost = true end
            break
        end
    end
    if string.find(low, "whole family", 1, true) or string.find(low, "entire family", 1, true) then f.wholeFamily = true end
    -- where they sheltered (rank: the place that was really theirs wins; "lost her in the evacuation" is not a refuge)
    if string.find(low, "church", 1, true) and string.find(low, "basement", 1, true) then f.refuge, f.refugeRank = "the church basement", 4
    elseif string.find(low, "church", 1, true) then f.refuge, f.refugeRank = "the church", 3
    elseif string.find(low, "basement", 1, true) then f.refuge, f.refugeRank = "a basement", 2
    elseif string.find(low, "school", 1, true) then f.refuge, f.refugeRank = "the school shelter", 2
    elseif string.find(low, "evacuation point", 1, true) or string.find(low, "evacuation center", 1, true) or string.find(low, "evacuation camp", 1, true)
        or string.find(low, "evacuation shelter", 1, true) then f.refuge, f.refugeRank = "the evacuation point", 1 end
    if string.find(low, "railroad", 1, true) or string.find(low, "tracks", 1, true) then f.road = "walking the railroad tracks at night"
    elseif string.find(low, "highway", 1, true) or string.find(low, "i-65", 1, true) then f.road = "coming off the highway"
    elseif string.find(low, "woods", 1, true) then f.road = "out of the woods" end
    local best = nil
    for _, town in ipairs(M.towns) do
        local i = string.find(t, town, 1, true)
        if i and (best == nil or i < best[1]) then best = { i, town } end
    end
    f.place = best and best[2] or nil
    local job = string.match(t, "worked as an? ([^,%.;]+)") or string.match(t, "[Ww]as an? ([^,%.;]+)")
        or string.match(t, "[Oo]wned ([^,%.;]+)") or string.match(t, "[Rr]an ([^,%.;]+)")
    if job then job = string.sub(job, 1, 48) end
    f.job = job
    if string.find(low, "truck", 1, true) or string.find(low, "18-wheeler", 1, true) then f.trucker = true end
    if string.find(low, "salon", 1, true) or string.find(low, "hair", 1, true) or string.find(low, "barber", 1, true) then f.hair = true end
    return f
end

local function ageOf(uid) if M.ageOf then local ok, a = pcall(M.ageOf, uid); if ok and tonumber(a) then return tonumber(a) end end return nil end
local function pairOf(a, b) if M.pairRow then return M.pairRow(a, b, false) end return nil end

-- the shared record for a pair (made once; remade only when one of the stories changed - same uids, same choices)
function M.togetherRow(a, b)
    if M.settings.sharedPast == false or a == nil or b == nil then return nil end
    a, b = tostring(a), tostring(b)
    local key, lo, hi = M.pairKey(a, b)
    local ta, tb = M.storyText(lo), M.storyText(hi)
    local sig = hash(ta .. "|" .. tb)
    local all = bucket("together")
    local row = all[key]
    if type(row) == "table" and row.sig == sig then return row, lo, hi end
    local fa, fb = M.storyFacts(ta), M.storyFacts(tb)
    local agA, agB = ageOf(lo), ageOf(hi)
    local pr = pairOf(lo, hi)
    local seededBefore = pr and type(pr.why) == "table" and pr.why[1] == "together since before"
    local fits = agA ~= nil and agB ~= nil and math.min(agA, agB) >= M.togetherCfg.beforeMinAge and math.abs(agA - agB) <= M.togetherCfg.beforeMaxGap
    if agA == nil or agB == nil then fits = true end
    row = { sig = sig, made = hours() }
    if seededBefore and fits then
        row.era = "before"
        local maxY = math.max(1, math.min(15, (math.min(agA or 30, agB or 30)) - 19))
        row.years = 1 + hash(key .. "#years") % maxY
    else
        row.era = "after"
        local today = math.max(1, math.floor(hours() / 24))
        row.metDay = 1 + hash(key .. "#met") % math.max(1, math.min(7, today))
    end
    -- who the "host" is (the place they met is theirs) and who arrived
    local host, guest, fh, fg = lo, hi, fa, fb
    if (row.era == "after" and (fb.refugeRank or 0) > (fa.refugeRank or 0)) or (row.era == "before" and fb.place and not fa.place) then host, guest, fh, fg = hi, lo, fb, fa end
    local hn, gn = firstOf(nameOf(host)), firstOf(nameOf(guest))
    if row.era == "after" then
        local where = fh.refuge or fg.refuge or "a shelter"
        local town = fh.place or (fh.refuge == nil and fg.place) or nil -- the host's town (where the refuge was)
        row.met = "met after the outbreak in " .. where .. (town and (" in " .. town) or "") .. ": " .. gn .. " turned up there"
            .. (fg.road and (" after " .. fg.road) or "") .. " and " .. hn .. " took them in"
    else
        local town = fh.place or fg.place or "town"
        local how
        if fg.trucker and fh.hair then how = gn .. " drove trucks through " .. town .. " and kept coming back to " .. hn .. "'s chair for a haircut"
        elseif fh.trucker and fg.hair then how = hn .. " drove trucks through " .. town .. " and kept coming back to " .. gn .. "'s chair for a haircut"
        else how = gn .. (fg.job and (" (" .. fg.job .. ")") or "") .. " kept running into " .. hn .. (fh.job and (" (" .. fh.job .. ")") or "") .. " around " .. town end
        row.met = "met in " .. town .. " " .. tostring(row.years) .. " year" .. (row.years == 1 and "" or "s") .. " before the outbreak: " .. how
    end
    -- the child
    local ch, owner = nil, nil
    if fa.child and fa.child.lost then ch, owner = fa.child, lo elseif fb.child and fb.child.lost then ch, owner = fb.child, hi end
    if ch then
        row.child = { name = ch.name, word = ch.word, owner = owner, shared = (row.era == "before" and (row.years or 0) >= 3) or nil }
        if row.era == "before" and not row.child.shared then row.child.step = true end
    end
    if row.era == "before" then
        if fa.wholeFamily then row.fix = { uid = lo, text = "the 'whole family' they lost means their parents and siblings - " .. firstOf(nameOf(hi)) .. " made it with them" } end
        if fb.wholeFamily then row.fix = { uid = hi, text = "the 'whole family' they lost means their parents and siblings - " .. firstOf(nameOf(lo)) .. " made it with them" } end
    end
    all[key] = row
    log("together: " .. nameOf(lo) .. " + " .. nameOf(hi) .. " - " .. row.era .. (row.child and (", child " .. tostring(row.child.name) .. (row.child.shared and " (shared)" or (" (" .. firstOf(nameOf(row.child.owner)) .. "'s)"))) or ""))
    return row, lo, hi
end

-- late partners (dead partner ties) of a person
local function latePartners(uid)
    local out = {}
    if not M.tiesOf then return out end
    local ok, list = pcall(M.tiesOf, uid, nil, nil, true)
    for _, t in ipairs(ok and list or {}) do if t.type == "partner" and t.dead then out[#out + 1] = t end end
    return out
end
function M.livingPartnerTies(uid)
    local out = {}
    if not M.tiesOf then return out end
    local ok, list = pcall(M.tiesOf, uid, nil, nil, true)
    for _, t in ipairs(ok and list or {}) do if t.type == "partner" and not t.dead then out[#out + 1] = t end end
    return out
end

-- the shared past seen from 'me' (lines in plain words). third = the Overview's wording ("Viola ... her"), else the
-- prompt's ("you ... your")
function M.togetherFor(me, third)
    if M.settings.sharedPast == false or me == nil then return nil end
    me = tostring(me)
    local out = {}
    local today = math.floor(hours() / 24)
    local mn = firstOf(nameOf(me))
    local you, You, your, Your, were, they = "you", "You", "your", "Your", "were", "you"
    if third then you, You, your, Your, were, they = mn, mn, "their", "Their", "was", "they" end
    for _, p in ipairs(M.livingPartnerTies(me)) do
        local other = tostring(p.uid)
        local row = M.togetherRow(me, other)
        if row then
            local on = firstOf(nameOf(other))
            local e = { other = other, name = nameOf(other), era = row.era, lines = {} }
            local since = row.era == "before" and (tostring(row.years) .. " year" .. (row.years == 1 and "" or "s") .. " before the outbreak")
                or ("day " .. tostring(row.metDay) .. " (" .. tostring(math.max(0, today - (row.metDay or 0))) .. " days)")
            e.lines[#e.lines + 1] = (third and (mn .. " has been") or "You have been") .. " with " .. on .. " since " .. since .. ". " .. (third and "They" or "You two") .. " " .. row.met .. "."
            if row.child then
                local cn = row.child.name or ("the " .. row.child.word)
                if row.child.shared then
                    e.lines[#e.lines + 1] = Your .. " " .. row.child.word .. " " .. cn .. " (" .. (third and (mn .. "'s") or "yours") .. " and " .. on
                        .. "'s) was lost; both grieve and both still hope to find " .. cn .. "."
                elseif row.child.owner == me then
                    e.lines[#e.lines + 1] = on .. " knows about " .. your .. " " .. row.child.word .. " " .. cn .. ", cares, and is helping " .. you .. " look."
                else
                    e.lines[#e.lines + 1] = on .. "'s " .. row.child.word .. " " .. cn .. " was lost; " .. you .. " care" .. (third and "s" or "")
                        .. " about " .. cn .. " too and help" .. (third and "s" or "") .. " " .. on .. " look."
                end
            end
            if row.fix and row.fix.uid == me then e.lines[#e.lines + 1] = "When " .. they .. " say" .. (third and "s" or "") .. " " .. they .. " lost the whole family: " .. row.fix.text .. "." end
            -- the late partner(s): how the three came together
            for _, who in ipairs({ me, other }) do
                for _, lp in ipairs(latePartners(who)) do
                    if tostring(lp.uid) ~= me and tostring(lp.uid) ~= other then
                        local ln = firstOf(lp.name)
                        local otherSide = who == me and other or me
                        local both = false
                        if M.pairRow then both = M.pairRow(otherSide, lp.uid, false) ~= nil end
                        local t = "Before this, " .. (who == me and (you .. " " .. were) or (on .. " was")) .. " with " .. lp.name .. ", now dead"
                        if both then t = t .. "; the three of them came through it together, and both grieve " .. ln
                        elseif who == me then t = t .. "; " .. on .. " knows " .. you .. " still grieve" .. (third and "s" or "") .. " " .. ln
                        else t = t .. "; " .. you .. " know" .. (third and "s" or "") .. " " .. on .. " still grieves " .. ln end
                        e.lines[#e.lines + 1] = t .. "."
                        e.late = e.late or {}
                        e.late[#e.late + 1] = ln
                    end
                end
            end
            out[#out + 1] = e
        end
    end
    if #out == 0 then return nil end
    return out
end

-- the Overview "Together" lines
function M.togetherView(uid)
    local list = M.togetherFor(uid, true)
    if list == nil then return nil end
    local lines = {}
    for _, e in ipairs(list) do for _, l in ipairs(e.lines) do lines[#lines + 1] = l end end
    return lines
end


-- "With Josh; grieving Jorge" (the Overview partner line)
function M.partnerWord(uid)
    if M.settings.sharedPast == false then return nil end
    local living, late = {}, {}
    if not M.tiesOf then return nil end
    local ok, list = pcall(M.tiesOf, uid, nil, nil, true)
    for _, t in ipairs(ok and list or {}) do
        if t.type == "partner" then if t.dead then late[#late + 1] = firstOf(t.name) else living[#living + 1] = firstOf(t.name) end end
    end
    if #living == 0 and #late == 0 then return nil end
    local s = #living > 0 and ("With " .. table.concat(living, " & ")) or ""
    if #late > 0 then s = s .. (s ~= "" and "; " or "") .. "grieving " .. table.concat(late, " & ") end
    return s, #living > 0
end

table.insert(M.requestExtras, function(req, player, listener, now)
    if M.settings.sharedPast == false or listener == nil or listener.record == nil then return end
    local ok, list = pcall(M.togetherFor, listener.record.uid)
    if ok and list ~= nil then
        local t = {}
        for _, e in ipairs(list) do t[#t + 1] = { n = e.name, era = e.era, lines = e.lines } end
        req.together = t
    end
end)

-- every existing partner pair, once (old saves)
function M.togetherBackfill()
    if M.settings.sharedPast == false then return 0 end
    local st = bucket("togetherFill")
    if st.done then return 0 end
    st.done = hours()
    local n = 0
    local keys = {}
    for key, row in pairs(bucket("pairs")) do if type(row) == "table" and row.t == "partner" then keys[#keys + 1] = key end end
    table.sort(keys)
    for _, key in ipairs(keys) do
        local a, b = string.match(key, "^(.-)|(.*)$")
        if a and b and not isDead(a) and not isDead(b) then
            local ok = pcall(M.togetherRow, a, b)
            if ok then n = n + 1 end
        end
    end
    log("together: backfilled " .. n .. " partner pair(s)")
    return n
end
if type(Events) == "table" and type(Events.OnGameStart) == "table" and type(Events.OnGameStart.Add) == "function" then
    Events.OnGameStart.Add(function() pcall(M.togetherBackfill) end)
end

return M
