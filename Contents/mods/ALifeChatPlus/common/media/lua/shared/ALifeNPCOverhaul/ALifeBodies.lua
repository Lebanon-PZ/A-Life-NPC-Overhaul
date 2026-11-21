-- A-Life NPC Overhaul: recognizing bodies.
-- Every 10 minutes: people near a dead A-Life NPC check who it was.
--   same group / household / bonded -> grief line, a memory, and the group hears it
--   someone you met                 -> you recognize them (halo text)
-- If they died by your hand and someone saw, ALifeMemory already holds that; here they find the body.

require "ALifeNPCOverhaul/AA_Side"
local TAG = "[ALifeBodies]"
ALifeBodies = ALifeBodies or {}
local B = ALifeBodies
B.RADIUS = 8
B.seen = {}          -- corpse uid -> true per session, so each body is found once per viewer

-- 42.21: these collections may not answer :get(i); walk the iterator first
local function eachOf(coll, fn)
    if coll == nil then return end
    local ok = pcall(function()
        local it = coll:iterator()
        while it:hasNext() do fn(it:next()) end
    end)
    if ok then return end
    pcall(function() for i = 0, coll:size() - 1 do fn(coll:get(i)) end end)
end
local function roll(n) return type(ZombRand) == "function" and ZombRand(n) or 0 end
local function pick(l) return l[roll(#l) + 1] end
local function nameOf(r)
    local N = ProjectALife and ProjectALife.Names
    local ok, n = pcall(function() return N.of(r) end)
    return ok and n and tostring(n) or "them"
end
local function groupOf(r)
    local m = type(r) == "table" and type(r.memory) == "table" and r.memory or {}
    return m.groupId or r.factionId or m.factionId
end

B.GRIEF = { "No... %s. Not %s.", "That's %s. Oh God, that's %s.", "%s? Somebody cover %s up." }
B.TURNED = { "That's %s. They turned. They actually turned.", "Don't look at it. That's not %s anymore." }

function B.records()
    local map, reg = {}, ProjectALife and ProjectALife.ActorRegistry
    if reg then pcall(reg.each, function(r) if r.uid then map[r.uid] = r end return false end) end
    return map
end

-- dead A-Life people in the loaded cell: uid, x, y, turned
function B.bodies()
    local out = {}
    pcall(function()
        eachOf(getCell():getObjectList(), function(o)
            if instanceof(o, "IsoZombie") or instanceof(o, "IsoDeadBody") then
                local md = o:getModData()
                if md and md.ProjectALifeUID then
                    out[#out + 1] = { uid = md.ProjectALifeUID, x = o:getX(), y = o:getY(), turned = instanceof(o, "IsoZombie") }
                end
            end
        end)
    end)
    return out
end

function B.check()
    if ALifeMerge and ALifeMerge.skip("bodies") then return end
    local Talk, reg = ProjectALife and ProjectALife.Talk, ProjectALife and ProjectALife.ActorRegistry
    if Talk == nil or reg == nil then return end
    local recs, bodies = B.records(), B.bodies()
    if #bodies == 0 then return end
    local player = ALifeSide.campPlayer()
    for _, b in ipairs(bodies) do
        local dead = recs[b.uid]
        if dead then
            -- you
            local pk = "p:" .. tostring(b.uid)
            if player and not B.seen[pk] and (player:getX() - b.x) ^ 2 + (player:getY() - b.y) ^ 2 <= B.RADIUS ^ 2 then
                local met = ALifeStory and ALifeStory.get and ALifeStory.get(dead)
                if met then B.seen[pk] = true; pcall(ALifeLetter, player, "You recognize " .. nameOf(dead)) end
            end
            -- them
            for uid, r in pairs(recs) do
                local key = tostring(uid) .. ">" .. tostring(b.uid)
                if uid ~= b.uid and r.lifecycle == "active" and not B.seen[key] and groupOf(r) ~= nil and groupOf(r) == groupOf(dead) then
                    local shell = Talk.shellFor and Talk.shellFor(uid)
                    local ok, x, y = pcall(function() return shell:getX(), shell:getY() end)
                    if ok and x and (x - b.x) ^ 2 + (y - b.y) ^ 2 <= B.RADIUS ^ 2 then
                        B.seen[key] = true
                        local n = nameOf(dead)
                        pcall(ProjectALife.Speech.say, shell, string.format(pick(b.turned and B.TURNED or B.GRIEF), n, n), {})
                        if ALifeMemory then
                            pcall(ALifeMemory.add, r, "you found " .. n .. (b.turned and " turned" or " dead"))
                        end
                    end
                end
            end
        end
    end
end

if Events ~= nil and Events.EveryTenMinutes ~= nil then
    ALifeHealth.add(Events.EveryTenMinutes, "ALifeBodies", function()
        local ok, err = pcall(B.check)
        if not ok and not B.warned then B.warned = true; print(TAG .. " check failed: " .. tostring(err)) end
    end)
end
print(TAG .. " loaded")
