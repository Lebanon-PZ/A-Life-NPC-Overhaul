-- A-Life NPC Overhaul: the groups you know, and where you stand - in words, never numbers.
-- Right-click anywhere > "Groups you know". Only groups you've actually met, dealt with, or heard about appear.
-- Standing comes from the game's own reputation (Jeem's standing ladder when it's there, A-Life's otherwise),
-- plus what word is going around about you, and any hold you have on them (a prisoner, a tribute deal).

local TAG = "[ALifeFactionsMenu]"
ALifeFactionsMenu = ALifeFactionsMenu or {}
local F = ALifeFactionsMenu

F.WORDS = {
    hostile = "Hostile. They'd shoot you on sight.",
    careful = "Wary. They don't trust you.",
    neutral = "Neutral. They'll hear you out.",
    friendly = "Friendly. You're welcome around them.",
    allied = "Allied. They'd stand with you.",
}

local function title(fid)
    local ok, f = pcall(function() return ProjectALife.Catalog.faction(fid) end)
    return ok and type(f) == "table" and (f.title or f.name) or tostring(fid)
end

function F.lines(player)
    local J = ProjectALifeJimmy
    local S = J and J.StandingService
    local key = nil
    pcall(function() key = J.BaseAreas.who(player).key end)
    local seen, list = {}, {}
    local function add(fid) if fid ~= nil and not seen[fid] then seen[fid] = true; list[#list + 1] = fid end end
    if S ~= nil and key ~= nil then
        local ok, known = pcall(S.knownFactions, key)
        if ok and type(known) == "table" then for _, f in ipairs(known) do add(f) end end
    end
    local met = type(ModData) == "table" and ModData.getOrCreate("ALifeChatPlus.Upkeep").met or {}
    for f in pairs(met or {}) do add(f) end
    local out = {}
    local bkey = ALifeBonds and ALifeBonds.keyOf(player) or nil
    for _, fid in ipairs(list) do
        local own = false
        pcall(function() own = S ~= nil and S.isOwn(key, fid) == true end)
        if not own then
            local label = "neutral"
            pcall(function() label = S.labelFor(key, fid) or label end)
            local parts = { "<RGB:1,1,1> " .. title(fid) .. " <LINE> <RGB:0.8,0.8,0.8> " .. (F.WORDS[label] or F.WORDS.neutral) }
            pcall(function()
                local b = S.breakdown(key, fid)
                if (tonumber(b.rumor) or 0) > 0 then parts[#parts + 1] = "Good things are being said about you."
                elseif (tonumber(b.rumor) or 0) < 0 then parts[#parts + 1] = "Bad things are being said about you." end
            end)
            pcall(function()
                local P = ALifeBondsPower
                if P and P.dealOf(bkey, fid) ~= nil then parts[#parts + 1] = "They pay you tribute." end
                for _, c in pairs(P.state().cap or {}) do if c.fid == fid then parts[#parts + 1] = "You're holding one of theirs."; break end end
            end)
            if met and met[fid] and met[fid].day then parts[#parts + 1] = "First met on day " .. tostring(met[fid].day) .. "." end
            out[#out + 1] = table.concat(parts, " <LINE> ")
        end
    end
    return out
end

-- RimWorld-style overview: factions and communities, your goodwill with each (numbers), and who's allied or at war.
-- Only available with immersion off (A-Life Talk setting immersive=false); with it on you read people in the world.
local function immersive()
    local M = ALifeLLMTalk
    return not (type(M) == "table" and type(M.settings) == "table" and M.settings.immersive == false)
end
local function signed(v) v = math.floor(tonumber(v) or 0); return (v > 0 and "+" or "") .. tostring(v) end
local function col(v) v = tonumber(v) or 0; if v >= 15 then return "<RGB:0.5,0.9,0.5>" elseif v <= -15 then return "<RGB:0.95,0.45,0.4>" end return "<RGB:0.85,0.85,0.85>" end

function F.factionLines(player)
    local out = {}
    local M = ALifeLLMTalk
    local J = ProjectALifeJimmy
    local S = J and J.StandingService
    local key = nil
    pcall(function() key = J.BaseAreas.who(player).key end)
    local list = {}
    pcall(function() list = select(1, M.activeFactions()) or {} end)
    local pol = {}
    pcall(function() pol = M.store().politics or {} end)
    local wordScore = (type(M) == "table" and M.wordScore) or {}
    for _, f in ipairs(list) do
        local fid = f.id
        local label, score = "neutral", 0
        pcall(function() label = S.labelFor(key, fid) or label end)
        pcall(function() local b = S.breakdown(key, fid); score = tonumber(b.total or b.score or b.value) or score end)
        if score == 0 then score = wordScore[label] or 0 end
        local band = M.isBand and M.isBand(fid) and M.bandById and M.bandById(fid) or nil
        if band then
            score = M.bandGoodwill(band, player)
            label = score >= 40 and "friendly" or (score >= 15 and "warm" or (score <= -40 and "hostile" or (score <= -15 and "wary" or "neutral")))
        end
        local leader = ""
        pcall(function() local uid = pol.leaders and pol.leaders[fid]; local r = uid and ProjectALife.ActorRegistry.read(uid); leader = r and ProjectALife.Names.of(r) or "" end)
        local rel = {}
        for k, st in pairs(pol.st or {}) do
            local a, b = string.match(k, "^(.-)|(.*)$")
            local other = a == fid and b or (b == fid and a or nil)
            if other and st ~= "peace" then rel[#rel + 1] = st .. " with " .. (M.factionName and M.factionName(other) or other) end
        end
        out[#out + 1] = string.format("%s%s <RGB:1,1,1> %s  <RGB:0.7,0.7,0.7> (%d people%s) <LINE> <RGB:0.8,0.8,0.8> goodwill %s%s <RGB:0.8,0.8,0.8> (%s)%s",
            "", "", (M.factionName and M.factionName(fid) or title(fid)), f.n or 0, leader ~= "" and (", led by " .. leader) or "",
            col(score), signed(score), label .. (band and band.origin and (", originally " .. title(band.origin)) or "") .. (band and band.history and band.history[#band.history] and (" <LINE> <RGB:0.65,0.65,0.65> latest: " .. band.history[#band.history].t) or ""), #rel > 0 and (" <LINE> <RGB:0.75,0.7,0.6> " .. table.concat(rel, "; ")) or "")
    end
    return out
end

function F.communityLines(player)
    local out = {}
    local M = ALifeLLMTalk
    if type(M) ~= "table" or type(M.nbActive) ~= "function" then return out end
    for _, b in ipairs(M.nbActive()) do
        local tier, eff = "neutral", 0
        pcall(function() tier, eff = M.nbStanding(b, player) end)
        local d = type(b.dir) == "table" and b.dir or {}
        local ties = {}
        for id, v in pairs(d.ties or {}) do
            local o = M.nbOf and M.nbOf(id)
            local st = M.dirTieState and M.dirTieState(v) or "neutral"
            local hidden = type(d.secret) == "table" and d.secret[id] == true and not (M.dynSecretKnown and M.dynSecretKnown(b, player))
            if hidden then st = "neutral" end
            if o and st ~= "neutral" then ties[#ties + 1] = (M.dirTieWords and M.dirTieWords[st] or st) .. ": " .. tostring(o.name) .. " (" .. signed(v) .. ")" end
        end
        local goals = {}
        for _, slot in ipairs({ "day", "week", "month" }) do
            local g = d.goals and d.goals[slot]
            if g then goals[#goals + 1] = slot .. ": " .. tostring(M.dirGoalWords and M.dirGoalWords[g.g] or g.g):gsub("%%s", "revenge") end
        end
        out[#out + 1] = string.format("<RGB:1,1,1> %s <RGB:0.7,0.7,0.7> (%d people%s, %s) <LINE> <RGB:0.8,0.8,0.8> goodwill %s%s <RGB:0.8,0.8,0.8> (%s) - morale %d, food %s <LINE> <RGB:0.7,0.8,0.9> %s / %s%s%s",
            tostring(b.name), b.crewN or 0, b.leaderName and (", led by " .. b.leaderName) or "", tostring(b.stage),
            col(eff), signed(eff), tostring(tier), math.floor(tonumber(b.morale) or 0), M.nbFoodWord and M.nbFoodWord(b) or "?",
            tostring(d.rule or "?"), tostring(d.creed or "?"),
            #goals > 0 and (" <LINE> <RGB:0.75,0.75,0.75> goals - " .. table.concat(goals, "; ")) or "",
            #ties > 0 and (" <LINE> <RGB:0.75,0.7,0.6> " .. table.concat(ties, "; ")) or "")
    end
    return out
end

function F.show(player)
    local parts = { "<SIZE:medium> Factions <LINE> <SIZE:small> " }
    local ok, fl = pcall(F.factionLines, player)
    if ok and #fl > 0 then parts[#parts + 1] = table.concat(fl, " <LINE> <LINE> ") else parts[#parts + 1] = "<RGB:0.7,0.7,0.7> None known." end
    parts[#parts + 1] = " <LINE> <LINE> <SIZE:medium> <RGB:1,1,1> Communities <LINE> <SIZE:small> "
    local ok2, cl = pcall(F.communityLines, player)
    if ok2 and #cl > 0 then parts[#parts + 1] = table.concat(cl, " <LINE> <LINE> ") else parts[#parts + 1] = "<RGB:0.7,0.7,0.7> None yet." end
    local text = table.concat(parts)
    if ISModalRichText == nil or getCore == nil then print(TAG .. " " .. text); return end
    local w, h = 640, 640
    local x = math.max(0, (getCore():getScreenWidth() - w) / 2)
    local y = math.max(0, (getCore():getScreenHeight() - h) / 2)
    local modal = ISModalRichText:new(x, y, w, h, text, false, nil, nil, 0)
    modal:initialise()
    modal:addToUIManager()
end

if Events ~= nil and Events.OnFillWorldObjectContextMenu ~= nil then
    ALifeRadial.addFiller("factions", "windows", function(playerNum, context)   -- 0.5.11: radial registry
        local player = getSpecificPlayer(playerNum)
        if player == nil or context == nil or immersive() then return end
        context:addOption(ALifeTr("IGUI_ALCP_Menu_Factions_communities", "Factions & communities"), player, F.show)
    end)
end
print(TAG .. " loaded")
