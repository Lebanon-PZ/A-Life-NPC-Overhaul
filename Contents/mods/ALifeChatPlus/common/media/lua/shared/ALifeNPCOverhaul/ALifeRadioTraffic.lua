-- A-Life NPC Overhaul: other people on the air.
-- With a two-way radio on, you sometimes catch other groups talking - real groups A-Life is running off-screen,
-- in range of your set, saying what they're actually doing: the scavenging run they're on and where, what they're
-- short of, their morale, what's going around (including about you, if word has reached them). The AI writes it from
-- their real state; it shows as radio chatter like your base's replies. Nothing about you is ever sent to them.

require "ALifeNPCOverhaul/AA_Side"
local TAG = "[ALifeRadioTraffic]"
ALifeRadioTraffic = ALifeRadioTraffic or {}
local RT = ALifeRadioTraffic
RT.CHANCE = 18                  -- percent per in-game 10 minutes, while your radio is on and someone is in range
RT.GROUP_COOLDOWN_H = 6         -- a group is on the air at most this often (game hours)
RT.last = {}

local function roll(n) return type(ZombRand) == "function" and ZombRand(n) or 0 end
local function hours() local ok, h = pcall(function() return getGameTime():getWorldAgeHours() end); return ok and h or 0 end

local function factionTitle(fid)
    local ok, f = pcall(function() return ProjectALife.Catalog.faction(fid) end)
    if ok and type(f) == "table" then return f.title or f.name or tostring(fid) end
    return tostring(fid or "survivors")
end

function RT.candidates(player, range)
    local out = {}
    local store = type(ModData) == "table" and type(ModData.get) == "function" and ModData.get("ProjectALife.Squads.v1") or nil
    if type(store) ~= "table" or type(store.squads) ~= "table" then return out end
    local px, py = player:getX(), player:getY()
    local h = hours()
    for id, s in pairs(store.squads) do
        if type(s) == "table" and s.x and s.y and h - (RT.last[id] or -1e9) >= RT.GROUP_COOLDOWN_H then
            local d = math.sqrt((s.x - px) ^ 2 + (s.y - py) ^ 2)
            if d <= range then out[#out + 1] = { id = id, s = s, d = d } end
        end
    end
    return out
end

function RT.tick()
    local ai, RD = ALifeChatAI, ALifeRadio
    if ai == nil or not ai.alive() or RD == nil or type(RD.walkie) ~= "function" then return end
    if roll(100) >= RT.CHANCE then return end
    local player = ALifeSide.campPlayer()
    if player == nil then return end
    local itemId, range = RD.walkie(player)
    if itemId == nil then return end
    local list = RT.candidates(player, range)
    if #list == 0 then return end
    local c = list[roll(#list) + 1]
    local s = c.s
    RT.last[c.id] = hours()
    local n = 0
    for _ in pairs(type(s.members) == "table" and s.members or {}) do n = n + 1 end
    local needs = type(s.needs) == "table" and s.needs or {}
    local heard = ""
    pcall(function()
        local mem = ModData.getOrCreate("ALifeChatPlus.Memory")
        local w = mem.world or {}
        local g = mem.groups and mem.groups[s.factionId] or {}
        local parts = {}
        for i = math.max(1, #w - 2), #w do if w[i] then parts[#parts + 1] = w[i] end end
        for i = math.max(1, #g - 1), #g do if g[i] then parts[#parts + 1] = g[i] end end
        heard = table.concat(parts, " | ")
    end)
    local fields = { "mode=radio", "group=" .. ai.clean(factionTitle(s.factionId), 60), "squad=" .. ai.clean(s.name, 60),
        "members=" .. n, "task=" .. ai.clean(type(s.task) == "table" and s.task.label or "holding position", 80),
        "needs=" .. string.format("food %d, water %d, ammo %d, meds %d", tonumber(needs.food) or 50, tonumber(needs.water) or 50,
            tonumber(needs.ammo) or 50, tonumber(needs.meds) or 50),
        "morale=" .. tostring(s.morale or 0.5), "heard=" .. ai.clean(heard, 700),
        "day=" .. tostring(math.floor(hours() / 24) + 1) }
    ai.request(fields, function(lines)
        if lines == nil then return end
        local out = {}
        for _, l in ipairs(lines) do
            local t = string.match(l, "^line=(.*)$")
            if t ~= nil and t ~= "" then out[#out + 1] = t end
        end
        if #out > 0 then
            local ra = ProjectALifeJimmy and ProjectALifeJimmy.Residents and ProjectALifeJimmy.Residents.radio
            if ra ~= nil and type(ra.reply) == "function" then pcall(ra.reply, player, out) end
        end
    end, 10000, 9)
end

local failed = false
if Events ~= nil and Events.EveryTenMinutes ~= nil then
    ALifeHealth.add(Events.EveryTenMinutes, "ALifeRadioTraffic", function()
        if ALifeMerge and ALifeMerge.skip("radioTraffic") then return end
        if failed then return end
        local ok, err = pcall(RT.tick)
        if not ok then failed = true; print(TAG .. " failed, off for this session: " .. tostring(err)) end
    end)
end
print(TAG .. " loaded")
