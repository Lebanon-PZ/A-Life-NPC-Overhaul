-- A-Life NPC Overhaul: the world leaves you messages.
-- SIGNS - territory. Groups holding a place mark it: painted boards at the edges of their outposts and where a group
--   has dug in ("KETTLE WORKS. TURN BACK."). Hover one and you read it. They tell you whose ground you're on.
-- NOTES - real paper, read with Zomboid's own Read (A-Life's letter format). Written by real groups from their real
--   state and memories, left where people would leave them:
--   to you, if they know you: "We see you. Get out of our town." / "Please. We didn't do anything to you." /
--     "Hey Rod - thanks for the bandages. Door's open." (your name only if you told them)
--   to their own people or other groups: "Gone to the pharmacy for meds. Back at the farmhouse by dark." - and when a
--     note says where someone is, it's TRUE: the direction and distance come from where that group actually is.
--   at your base while you're out, from groups who know where it is: thanks, offers, or threats.
-- The AI writes them when it's running (with each group's story and memories); plain templates otherwise.

require "ALifeNPCOverhaul/AA_Side"
local TAG = "[ALifeNotes]"
ALifeNotes = ALifeNotes or {}
local N = ALifeNotes
N.STORE = "ALifeChatPlus.Notes"
N.NOTE_CHANCE = 30              -- percent per game hour a note gets left somewhere near you
N.BASE_NOTE_CHANCE = 12         -- percent per game hour, while you're away from your base, for a note there
N.NEAR_MIN, N.NEAR_MAX = 25, 70 -- notes are left this far from you (out of sight, in a building)
N.GROUP_RANGE = 900             -- groups this close can be the writers
N.SIGN_RANGE = 120              -- signs go up at places this close to you (the squares must be loaded)
N.PAPER, N.BOARD, N.BOARD_FALLBACK = "Base.SheetPaper2", "ALifeChatPlus.SignBoard", "Base.Plank"

local function store()
    local s = type(ModData) == "table" and ModData.getOrCreate(N.STORE) or {}
    s.signs, s.squadSigns, s.lastBase = s.signs or {}, s.squadSigns or {}, s.lastBase or -1e9
    return s
end
local function roll(n) return type(ZombRand) == "function" and ZombRand(n) or 0 end
local function hours() local ok, h = pcall(function() return getGameTime():getWorldAgeHours() end); return ok and h or 0 end
local function newItem(t) if type(instanceItem) ~= "function" then return nil end local ok, i = pcall(instanceItem, t); return ok and i or nil end
local function title(fid)
    local ok, f = pcall(function() return ProjectALife.Catalog.faction(fid) end)
    return ok and type(f) == "table" and (f.title or f.name) or "survivors"
end

-- compass direction and rough distance, in words, from (x1,y1) to (x2,y2)
function N.direction(x1, y1, x2, y2)
    local dx, dy = x2 - x1, y2 - y1
    local d = math.sqrt(dx * dx + dy * dy)
    local a = math.deg(math.atan2(-dy, dx))
    if a < 0 then a = a + 360 end
    local names = { "east", "northeast", "north", "northwest", "west", "southwest", "south", "southeast" }
    local dir = names[math.floor((a + 22.5) / 45) % 8 + 1]
    local far = (d < 150 and "just") or (d < 400 and "a few blocks") or (d < 900 and "about half a mile") or (d < 1800 and "about a mile")
        or "a few miles"
    return dir, far, d
end

-- a loaded square inside a building, between min and max tiles from (x, y)
function N.indoorSquare(x, y, z, minD, maxD)
    local cell = getCell()
    if cell == nil then return nil end
    for _ = 1, 40 do
        local r = minD + roll(maxD - minD + 1)
        local a = math.rad(roll(360))
        local sx, sy = math.floor(x + math.cos(a) * r), math.floor(y + math.sin(a) * r)
        local sq = cell:getGridSquare(sx, sy, z)
        if sq ~= nil and sq:getRoom() ~= nil and sq:isFree(false) then return sq end
    end
    return nil
end
function N.outdoorSquare(x, y, z)
    local cell = getCell()
    for dx = -2, 2 do
        for dy = -2, 2 do
            local sq = cell and cell:getGridSquare(math.floor(x) + dx, math.floor(y) + dy, z or 0)
            if sq ~= nil and sq:getRoom() == nil and sq:isFree(false) then return sq end
        end
    end
    return nil
end

function N.leaveNote(square, heading, body)
    local paper = newItem(N.PAPER)
    if paper == nil or square == nil or type(paper.addPage) ~= "function" then return false end
    pcall(function() paper:setName(heading); paper:setCustomName(true) end)
    paper:addPage(1, body)
    pcall(function() paper:setLockedBy("alife_letter") end)
    pcall(function() paper:getModData().ALifeLetter = { event = "chatplus_note" } end)
    return pcall(square.AddWorldInventoryItem, square, paper, 0.3 + roll(40) / 100, 0.3 + roll(40) / 100, 0) == true
end

-- standing sign tile (art\alife_signs, tiledef 3827). Facing = the way the painted words point. Words on one side only:
-- S/E show the words to the camera, N/W show the plain back of the board (you're on the inside looking at it).
-- Used only once the .tiles/.pack load: the sprite must carry our own GroupName, else we drop the board item.
-- pre-1.0 claim signs: one painted sign per kind (how the group treats people). Sheet slots: S/E hostile 0/1,
-- neutral 2/3, friendly 4/5, slaver 6/7; N/W hostile 8/9, neutral 10/11, friendly 12/13, slaver 14/15.
N.SIGN_TILES = {
    hostile = { S = "alife_signs_01_0", E = "alife_signs_01_1", N = "alife_signs_01_8", W = "alife_signs_01_9" },
    neutral = { S = "alife_signs_01_2", E = "alife_signs_01_3", N = "alife_signs_01_10", W = "alife_signs_01_11" },
    friendly = { S = "alife_signs_01_4", E = "alife_signs_01_5", N = "alife_signs_01_12", W = "alife_signs_01_13" },
    slaver = { S = "alife_signs_01_6", E = "alife_signs_01_7", N = "alife_signs_01_14", W = "alife_signs_01_15" },
}
N.SIGN_TILE = N.SIGN_TILES.hostile
function N.signSprite(facing, kind)
    local set = N.SIGN_TILES[kind or "hostile"] or N.SIGN_TILE
    local name = set[facing] or set.S
    if type(getSprite) ~= "function" then return nil end
    local ok, spr = pcall(getSprite, name)
    if not ok or spr == nil then return nil end
    local ok2, group = pcall(function() return spr:getProperties():get("GroupName") end)
    if not ok2 or group ~= "Territory" then return nil end
    return spr
end

-- words toward (px, py): the one of N/E/S/W that points closest to them
function N.signFacing(square, px, py)
    if square == nil or px == nil or py == nil then return "S" end
    local dx, dy = px - square:getX(), py - square:getY()
    if math.abs(dy) >= math.abs(dx) then return dy < 0 and "N" or "S" end
    return dx < 0 and "W" or "E"
end
-- words away from (px, py): the back faces them (you plant it, the words face out)
local OPPOSITE = { N = "S", S = "N", E = "W", W = "E" }
function N.signFacingAway(square, px, py)
    if square == nil or px == nil or py == nil then return "S" end
    return OPPOSITE[N.signFacing(square, px, py)]
end

-- calls as in vanilla ISMoveableSpriteProps:placeMoveableInternal
-- extra: more ModData keys (claim signs carry ALifeClaim = sign id). Returns true, obj.
local function stamp(md, text, extra)
    md.ALifeSign = true; md.ALifeSignText = text
    for k, v in pairs(type(extra) == "table" and extra or {}) do md[k] = v end
end
function N.putSignTile(square, text, facing, kind, extra)
    local spr = N.signSprite(facing, kind)
    if spr == nil or square == nil or IsoObject == nil then return false end
    local ok, obj = pcall(IsoObject.new, getCell(), square, spr)
    if not ok or obj == nil then return false end
    pcall(function() stamp(obj:getModData(), text, extra) end)
    if not pcall(square.AddTileObject, square, obj) then return false end
    if ALifeSide.server() then pcall(function() obj:transmitCompleteItemToClients() end) end
    pcall(function() square:RecalcProperties() end)
    pcall(triggerEvent, "OnObjectAdded", obj)
    return true, obj
end

function N.putSign(square, text, facing, kind, extra)
    local okT, obj = N.putSignTile(square, text, facing, kind, extra)
    if okT then return true, obj end
    local board = newItem(N.BOARD) or newItem(N.BOARD_FALLBACK)
    if board == nil or square == nil then return false end
    pcall(function() board:setName("Sign: " .. text); board:setCustomName(true) end)
    pcall(function() stamp(board:getModData(), text, extra) end)
    if pcall(square.AddWorldInventoryItem, square, board, 0.5, 0.5, 0) == true then return true, board end
    return false
end

-- groups near (x, y) from A-Life's squad ledger
function N.groups(x, y, range)
    local out = {}
    local sq = type(ModData) == "table" and type(ModData.get) == "function" and ModData.get("ProjectALife.Squads.v1") or nil
    for id, s in pairs(type(sq) == "table" and type(sq.squads) == "table" and sq.squads or {}) do
        if type(s) == "table" and s.x and s.y then
            local d = math.sqrt((s.x - x) ^ 2 + (s.y - y) ^ 2)
            if d <= range then out[#out + 1] = { id = id, s = s, d = d } end
        end
    end
    table.sort(out, function(a, b) return a.d < b.d end)
    return out
end

-- what a group knows about you (from Chat Plus memory)
local function knownOf(fid)
    local ok, mem = pcall(function() return ModData.getOrCreate("ALifeChatPlus.Memory") end)
    if not ok then return "" end
    local g = mem.groups and mem.groups[fid] or {}
    local parts = {}
    for i = math.max(1, #g - 4), #g do if g[i] then parts[#parts + 1] = g[i] end end
    for _, w in ipairs(mem.world or {}) do parts[#parts + 1] = w end
    return table.concat(parts, " | ")
end

-- templates when the AI isn't running
N.PLAIN = {
    warn = { "We see you. Get out of our town.", "This is our place. Keep walking.", "You've been seen. Don't come back." },
    plea = { "Please. We don't want trouble. We have nothing worth taking.", "Leave us alone. We have kids." },
    friendly = { "Thanks for the help. If you need a place to rest, knock twice.", "We owe you one. Stay safe out there." },
    group = { "Gone %s, %s, for supplies. Back before dark.", "Meet back at the place %s of here, %s. Don't wait for us.",
        "Took the road %s. If you find this, we're %s that way." },
    sign = { "%s TERRITORY. TURN BACK.", "PRIVATE. %s. KEEP OUT.", "THIS IS %s GROUND." },
    -- claim signs by kind (tone=hostile|neutral|friendly|slaver)
    sign_hostile = { "%s TERRITORY. TURN BACK.", "PRIVATE. %s. KEEP OUT.", "THIS IS %s GROUND. GET OUT." },
    sign_neutral = { "%s GROUND. NO TROUBLE.", "%s. PASS THROUGH. DON'T TAKE.", "THIS IS %s LAND. KNOCK FIRST." },
    sign_friendly = { "%s. FRIENDS WELCOME.", "%s. TRADE AND REST HERE.", "%s. COME IN PEACE." },
    sign_slaver = { "%s GROUND. TRESPASSERS TAKEN.", "PROPERTY OF %s. YOU TOO.", "%s. WALK IN, WORK FOREVER." },
    base = { "Came by. Nobody home. We'll try again.", "Stopped by your place. Looks good. Watch the east side at night." },
}

-- a sign is a few painted words: drop anything the model echoed from its instructions ("GROUP: ...")
function N.cleanSign(t)
    t = string.upper(tostring(t or ""))
    for _, label in ipairs({ "KIND%s*:", "GROUP%s*:", "WHAT THEY ARE DOING", "DIRECTION", "DAY%s*%d", "THEIR BASE", "SIGN%s*:" }) do
        local i = string.find(t, label)
        if i then t = string.sub(t, 1, i - 1) end
    end
    t = string.gsub(string.gsub(t, "[^%w%s%.!',%-]", " "), "%s+", " ")
    t = string.gsub(string.gsub(t, "^[%s,%-]+", ""), "[%s,%-:]+$", "")
    local words, out = 0, {}
    for w in string.gmatch(t, "%S+") do words = words + 1; if words <= 8 then out[#out + 1] = w end end
    t = table.concat(out, " ")
    if #t < 4 then return "" end
    return t
end

-- write it (AI if running) and leave it
function N.write(kind, facts, deliver)
    local ai = ALifeChatAI
    local function plain()
        local list = N.PLAIN[kind] or N.PLAIN.group
        if kind == "sign" and facts.tone ~= nil and N.PLAIN["sign_" .. tostring(facts.tone)] then list = N.PLAIN["sign_" .. tostring(facts.tone)] end
        local t = list[roll(#list) + 1]
        if kind == "group" and string.find(t, "%s", 1, true) then t = string.format(t, facts.dir or "north", facts.far or "a few blocks")
        elseif kind == "sign" then t = string.format(t, string.upper(facts.group or "OUR")) end
        deliver(t)
    end
    if ai == nil or not ai.alive() then return plain() end
    local fields = { "mode=note", "kind=" .. kind }
    for k, v in pairs(facts) do fields[#fields + 1] = k .. "=" .. ai.clean(tostring(v), 600) end
    local sent = ai.request(fields, function(lines)
        local text = nil
        for _, l in ipairs(lines or {}) do text = text or string.match(l, "^text=(.*)$") end
        if text ~= nil and kind == "sign" then text = N.cleanSign(text) end
        if text ~= nil and text ~= "" then deliver(text) else plain() end
    end, 12000, 8)
    if not sent then plain() end
end

-- one hour: maybe a note near you, maybe one at your base, signs at places you're near
function N.tick()
    local player = ALifeSide.campPlayer()
    if player == nil then return end
    local px, py, pz = player:getX(), player:getY(), math.floor(player:getZ())
    local s = store()
    local groups = N.groups(px, py, N.GROUP_RANGE)
    -- signs: outposts' edges, and groups dug in close by. pre-1.0: with claim signs on, signs are only ever crafted
    -- from real parts by the group (ALifeClaimSign); the old free signs stay only as the "claim signs off" path.
    if not (type(ALifeClaimSign) == "table" and type(ALifeClaimSign.on) == "function" and ALifeClaimSign.on()) then
        N.signs(px, py, s, groups)
    end
    if ALifeMerge and ALifeMerge.skip("notes") then return end
    -- a note near you
    if #groups > 0 and roll(100) < N.NOTE_CHANCE then
        local sq = N.indoorSquare(px, py, pz, N.NEAR_MIN, N.NEAR_MAX)
        if sq ~= nil then
            local g = groups[roll(math.min(3, #groups)) + 1]
            local known = knownOf(g.s.factionId)
            local kind = "group"
            if known ~= "" then
                if string.find(known, "killed", 1, true) or string.find(known, "robbed", 1, true) or string.find(known, "attacked", 1, true) then
                    kind = (#(g.s.members or {}) <= 2) and "plea" or "warn"
                elseif string.find(known, "patched", 1, true) or string.find(known, "shared", 1, true) or string.find(known, "saved", 1, true)
                        or string.find(known, "fought beside", 1, true) or string.find(known, "gave you", 1, true) then
                    kind = "friendly"
                elseif g.d < 300 then kind = "warn" end
            end
            local dir, far = N.direction(sq:getX(), sq:getY(), g.s.x, g.s.y)
            local facts = { group = title(g.s.factionId), squad = g.s.name or "", known = known,
                task = type(g.s.task) == "table" and g.s.task.label or "", dir = dir, far = far,
                day = math.floor(hours() / 24) + 1 }
            N.write(kind, facts, function(text)
                N.leaveNote(sq, kind == "group" and "Note" or "Note for the stranger", text)
                ALifeHealth.note(TAG, "left a " .. kind .. " note (" .. tostring(facts.group) .. ")")
            end)
        end
    end
    -- a note at your base while you're out
    N.baseNote(px, py, s)
end

function N.signs(px, py, s, groups)
    -- A-Life outposts
    local op = type(ModData) == "table" and type(ModData.get) == "function" and ModData.get("ProjectALife.Outposts.v1") or nil
    for id, site in pairs(type(op) == "table" and type(op.sites) == "table" and op.sites or {}) do
        local b = type(site) == "table" and site.bounds or nil
        if b and not s.signs[id] then
            local cx, cy = (b.x1 + b.x2) / 2, (b.y1 + b.y2) / 2
            if math.sqrt((cx - px) ^ 2 + (cy - py) ^ 2) <= N.SIGN_RANGE then
                -- on the edge facing you
                local ex = math.max(b.x1, math.min(b.x2, px))
                local ey = math.max(b.y1, math.min(b.y2, py))
                local sq = N.outdoorSquare(ex, ey, b.z or 0)
                if sq ~= nil then
                    s.signs[id] = true
                    local facing = N.signFacing(sq, px, py)
                    N.write("sign", { group = title(site.factionId) }, function(text) N.putSign(sq, text, facing) end)
                end
            end
        end
    end
    -- groups holding a spot (a shelter or a rest), close to you
    for _, g in ipairs(groups) do
        local task = type(g.s.task) == "table" and tostring(g.s.task.label or "") or ""
        local holding = string.find(task, "shelter", 1, true) or string.find(task, "rest", 1, true) or string.find(task, "hold", 1, true)
        if holding and g.d <= N.SIGN_RANGE and hours() - (s.squadSigns[g.id] or -1e9) > 72 then
            local dx, dy = px - g.s.x, py - g.s.y
            local len = math.max(1, math.sqrt(dx * dx + dy * dy))
            local sq = N.outdoorSquare(g.s.x + dx / len * 25, g.s.y + dy / len * 25, 0)
            if sq ~= nil then
                s.squadSigns[g.id] = hours()
                local facing = N.signFacing(sq, px, py)
                N.write("sign", { group = title(g.s.factionId) }, function(text) N.putSign(sq, text, facing) end)
            end
        end
    end
end

function N.baseNote(px, py, s)
    if hours() - s.lastBase < 24 or roll(100) >= N.BASE_NOTE_CHANCE then return end
    local Jm = ProjectALifeJimmy
    local B = Jm and Jm.BaseAreas
    if B == nil then return end
    local ok, mem = pcall(function() return ModData.getOrCreate("ALifeChatPlus.Memory") end)
    if not ok then return end
    -- groups that know where your base is (you invited them, or told them)
    local writers = {}
    for _, list in pairs(mem.people or {}) do
        for _, l in ipairs(list) do
            if string.find(l, "invited you to their base", 1, true) or string.find(l, "base", 1, true) and string.find(l, "told you", 1, true) then
                writers[#writers + 1] = l
            end
        end
    end
    if #writers == 0 then return end
    local who = B.who(ALifeSide.campPlayer())
    for _, base in ipairs(B.basesFor(who.key, who.faction, false)) do
        for _, a in ipairs(B.areasOf(base.id) or {}) do
            local cx, cy = (a.x1 + a.x2) / 2, (a.y1 + a.y2) / 2
            if math.sqrt((cx - px) ^ 2 + (cy - py) ^ 2) > 150 then
                local sq = N.outdoorSquare(a.x1 - 1, cy, a.z or 0) or N.outdoorSquare(cx, a.y1 - 1, a.z or 0)
                if sq ~= nil then
                    s.lastBase = hours()
                    N.write("base", { base = base.name, known = writers[roll(#writers) + 1] }, function(text)
                        N.leaveNote(sq, "Note for " .. tostring(base.name), text)
                        ALifeHealth.note(TAG, "left a note at " .. tostring(base.name))
                    end)
                    return
                end
            end
            break
        end
    end
end

local failed = false
if Events ~= nil and Events.EveryHours ~= nil then
    ALifeHealth.add(Events.EveryHours, "ALifeNotes", function()
        if failed then return end
        local ok, err = pcall(N.tick)
        if not ok then failed = true; print(TAG .. " failed, off for this session: " .. tostring(err)) end
    end)
end
print(TAG .. " loaded")
