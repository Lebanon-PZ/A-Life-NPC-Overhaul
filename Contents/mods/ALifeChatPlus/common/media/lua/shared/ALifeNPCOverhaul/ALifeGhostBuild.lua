-- A-Life NPC Overhaul 0.8.12 (Rock List 2) / 0.9.0.1: GHOST BUILD (blueprints). The shared core.
-- You place a see-through build plan with no materials; the people who live at your base build it over time, from
-- what is really in the base's storage, with real tools, at a speed set by how good they are. Nothing from nothing.
--   * THE REGISTRY (G.TYPES, G.register): one entry per buildable type: id, label, stages (vanilla B42 build entities,
--     built in order: a wall is WoodenWallFrame, then WoodenWallLvl1), and optional hooks for later systems (crew,
--     power, ammo, upkeep, onThreat: empty now). A new type is one table entry; other mods may register their own.
--   * 0.9.0.1 EVERYTHING VANILLA BUILDS (G.loadCatalog): the same list vanilla's build menu uses
--     (ISBuildIsoEntity.GetAllBuildableEntities: every SpriteConfigManager object with a script and a recipe), named
--     the way the build menu names them (the entity's UiConfig skin style, else the recipe's name), grouped by the
--     recipe's build category. Stages come from the game itself (the script's previous stages: a wall needs its frame
--     first, walked back to something that can stand on bare ground). Recipes that need a fluid or energy are left out
--     (a settler can't carry a fluid out of a crate the way we take items). Ids are "e:<entity name>".
--   * COSTS: read from the game's own build recipe (SpriteConfigManager object info -> CraftRecipe inputs, time,
--     required skills; the calls vanilla's build menu makes), so the cost is the real game cost. Inputs that use up part
--     of a drainable (a torch's propane, paint, glue) are counted and taken in uses, like vanilla's
--     buildUtil.useDrainable, never as the whole item. G.FALLBACK holds the 42.21 numbers only when a recipe can't be read.
--   * THE QUEUE: global ModData "ALifeChatPlus_Ghost" (save + multiplayer): { seq, list = { plan, ... }, layouts, piles }.
--     A plan keeps its type id, stage, square, facing (nSprite) and state, so later types (turrets in 1.0) load in old
--     saves. A "down" plan (kind = "down") is something to take down instead.
--   * COMMANDS (ALifeCmd, the server decides): ghostPlace, ghostPlaceMany (a line or a box), ghostCancel, ghostMove,
--     ghostAssign (who builds it), ghostDown (take this down), ghostPile (a building stockpile), ghostSaveLayout /
--     ghostStamp / ghostDelLayout (saved layouts), ghostAsk -> ghostList.
-- The builders (walking, tools, materials, skill, XP, zombies) live in client/ALifeLLMTalk/ALifeTalk_Ghost.lua, the
-- same A-Life behaviour-module way the camp's other jobs work.
require "ALifeNPCOverhaul/AA_Side"
require "ALifeNPCOverhaul/ALifeCmd"

ALifeGhostBuild = ALifeGhostBuild or {}
local G = ALifeGhostBuild
local TAG = "[ALifeGhostBuild]"
G.VERSION = ALifeSide.MOD_VERSION
G.MODDATA = "ALifeChatPlus_Ghost"
G.DEFAULTS = {
    ghostBuild = true,        -- blueprints at your base, built by the people who live there
    ghostLeaderOnly = false,  -- multiplayer: only the base's owner places / cancels plans (off: any member)
    ghostRange = 60,          -- tiles: plans only this close to you
    ghostMax = 200,           -- most plans at once
    ghostBuilders = 2,        -- most people building at the same time
    ghostTimeMs = 100,        -- ms of real work per recipe time unit (a wall frame is 200 units = 20 s at the start)
    ghostFetchTiles = 12,     -- they look for materials in containers this far around the base too (tiles)
    ghostWasteChance = 25,    -- % chance someone only just good enough wastes material on a stage
    ghostLetters = true,      -- a letter when a plan is stuck (what's missing), and when one is done
    ghostAskMin = 30,         -- the same "still missing" letter at most every this many real minutes
    -- 0.9.0.1
    ghostAllVanilla = true,   -- everything vanilla's build menu builds can be planned (off: the six basic types only)
    ghostOutside = false,     -- plans outside your base (outposts): builders carry the materials out there
    ghostBaseTiles = 6,       -- "inside the base" reaches this many tiles past the base's edge
    ghostLineMax = 40,        -- most plans one line or box places
    ghostHaulTiles = 150,     -- building stockpiles count when they're this close to the base (tiles)
    ghostNoise = true,        -- hammering / sawing / welding makes real noise the dead hear
    ghostNoiseTiles = 20,     -- how far the noise carries (vanilla's own hammering radius is 20)
    ghostAutoRepair = true,   -- after damage, builders mend the base's walls and fences on their own (worst first)
    ghostRepairBelow = 60,    -- ...anything below this % health
    ghostApprentice = true,   -- a less skilled worker with nothing to do helps a builder: faster, and they learn more
    ghostAssignWaitMin = 30,  -- a plan given to one person waits this many real minutes for them, then anyone may take it
    ghostLayoutsMax = 30,     -- most saved layouts
}
function G.setting(key)
    local m = ALifeLLMTalk
    local v = nil
    if type(m) == "table" and type(m.settings) == "table" then v = m.settings[key] end
    if v == nil then v = G.DEFAULTS[key] end
    return v
end
function G.num(key) return tonumber(G.setting(key)) or G.DEFAULTS[key] end
function G.registerSettings()
    local m = ALifeLLMTalk
    if type(m) ~= "table" or type(m.settings) ~= "table" then return false end
    m.fileKeys = m.fileKeys or {}
    for k, v in pairs(G.DEFAULTS) do
        if m.settings[k] == nil then m.settings[k] = v end
        local have = false
        for _, x in ipairs(m.fileKeys) do if x == k then have = true end end
        if not have then m.fileKeys[#m.fileKeys + 1] = k end
    end
    return true
end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function log(m) print(TAG .. " " .. tostring(m)) end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return tonumber(h) or 0 end

----------------------------------------------------------------------------------------------------------------
-- the registry
----------------------------------------------------------------------------------------------------------------
G.TYPES, G.ORDER = G.TYPES or {}, G.ORDER or {}
-- def = { id, label, stages = { "EntityName", ... }, word = "wall" (what people call it), cat = "Walls", hooks = { ... } }
function G.register(def)
    if type(def) ~= "table" or type(def.id) ~= "string" or type(def.stages) ~= "table" or #def.stages == 0 then return false end
    def.hooks = type(def.hooks) == "table" and def.hooks or {}
    for _, h in ipairs({ "crew", "power", "ammo", "upkeep", "onThreat" }) do if def.hooks[h] == nil then def.hooks[h] = false end end
    def.word = def.word or string.lower(def.label or def.id)
    if G.TYPES[def.id] == nil then G.ORDER[#G.ORDER + 1] = def.id end
    G.TYPES[def.id] = def
    return true
end
G.register({ id = "wall", label = "Wooden wall", word = "wall", basic = true, stages = { "WoodenWallFrame", "WoodenWallLvl1" } })
G.register({ id = "fence", label = "Wooden fence", word = "fence", basic = true, stages = { "WoodFenceLvl1" } })
G.register({ id = "gate", label = "Fence gate", word = "gate", basic = true, stages = { "WoodFenceGate" } })
G.register({ id = "logwall", label = "Log wall", word = "log wall", basic = true, stages = { "LogWall" } })
G.register({ id = "sandbags", label = "Sandbag wall (guard post)", word = "sandbag", basic = true, stages = { "SandbagWall" } })
G.register({ id = "barbed", label = "Barbed wire fence", word = "barbed", basic = true, stages = { "BarbedWireFence" } })
G.BASIC_COUNT = 6

-- 42.21 build recipes (media/scripts/generated/entities), only used when the game's recipe can't be read
G.FALLBACK = {
    WoodenWallFrame = { time = 200, skill = { "Woodwork", 2 }, items = { { types = { "Base.Plank" }, n = 2 }, { types = { "Base.Nails" }, n = 2 } }, tools = { { "Base.Hammer", "Base.HammerStone", "Base.BallPeenHammer", "Base.ClubHammer" } } },
    WoodenWallLvl1 = { time = 200, skill = { "Woodwork", 2 }, items = { { types = { "Base.Plank" }, n = 2 }, { types = { "Base.Nails" }, n = 4 } }, tools = { { "Base.Hammer", "Base.HammerStone", "Base.BallPeenHammer", "Base.ClubHammer" } } },
    WoodFenceLvl1 = { time = 200, skill = { "Woodwork", 3 }, items = { { types = { "Base.Plank" }, n = 2 }, { types = { "Base.Nails" }, n = 2 } }, tools = { { "Base.Hammer", "Base.HammerStone", "Base.BallPeenHammer", "Base.ClubHammer" } } },
    WoodFenceGate = { time = 200, skill = { "Woodwork", 3 }, items = { { types = { "Base.Plank" }, n = 4 }, { types = { "Base.Nails" }, n = 4 }, { types = { "Base.Hinge" }, n = 2 }, { types = { "Base.Doorknob" }, n = 1 } }, tools = { { "Base.Hammer", "Base.HammerStone", "Base.BallPeenHammer", "Base.ClubHammer" } } },
    LogWall = { time = 200, items = { { types = { "Base.Log" }, n = 4 }, { types = { "Base.RippedSheets", "Base.RippedSheetsDirty", "Base.Twine", "Base.Rope", "Base.SheetRope" }, n = 4 } }, tools = {} },
    SandbagWall = { time = 80, items = { { types = { "Base.Sandbag" }, n = 3 } }, tools = {} },
    BarbedWireFence = { time = 200, skill = { "Woodwork", 5 }, items = { { types = { "Base.BarbedWire" }, n = 1 } }, tools = { { "Base.Hammer", "Base.HammerStone", "Base.BallPeenHammer", "Base.ClubHammer" } } },
}

-- the game's object info for a build entity (vanilla SpriteConfigManager.GetObjectInfoList, as the build menu does)
G.infoCache = G.infoCache or {}
function G.infoOf(name)
    if G.infoCache[name] ~= nil then return G.infoCache[name] or nil end
    local found = nil
    pcall(function()
        local infos = SpriteConfigManager.GetObjectInfoList()
        for i = 0, infos:size() - 1 do
            local info = infos:get(i)
            if info:getName() == name then found = info; break end
        end
    end)
    G.infoCache[name] = found or false
    return found
end
-- is this script item drainable (InputScript.isUsesPartialItem, decompiled 42.21: not ItemCount / Destroy / Keep and a
-- DRAINABLE item -> the recipe uses part of it)
local function drainableScript(it)
    local yes = false
    pcall(function() yes = it:isItemType(ItemType.DRAINABLE) == true end)
    return yes
end
-- { time, skill = { perkName, level }, items = { { types = { fullType... }, n, uses } }, tools = { { fullType... } }, real, unsupported }
G.costCache = G.costCache or {}
function G.costOf(name)
    if G.costCache[name] then return G.costCache[name] end
    local c = nil
    pcall(function()
        local info = G.infoOf(name)
        if info == nil then return end
        local r = info:getRecipe():getCraftRecipe()
        local out = { time = tonumber(r:getTime()) or 200, items = {}, tools = {}, real = true }
        local nSkills = tonumber(r:getRequiredSkillCount()) or 0
        for si = 0, nSkills - 1 do -- the hardest one counts (a builder is one "how good with their hands")
            pcall(function()
                local s = r:getRequiredSkill(si)
                local lv = tonumber(s:getLevel()) or 0
                if out.skill == nil or lv > out.skill[2] then out.skill = { tostring(s:getPerk():getName()), lv } end
            end)
        end
        local inputs = r:getInputs()
        for i = 0, inputs:size() - 1 do
            local inp = inputs:get(i)
            local rt = "Item"
            pcall(function() rt = tostring(inp:getResourceType()) end)
            if rt ~= "Item" and rt ~= "nil" then out.unsupported = rt end
            local types = {}
            local list = inp:getPossibleInputItems()
            local firstScript = nil
            for k = 0, list:size() - 1 do
                local it = list:get(k)
                if firstScript == nil then firstScript = it end
                types[#types + 1] = it:getFullName()
            end
            if #types > 0 then
                local keep = inp:isKeep() == true
                if keep then out.tools[#out.tools + 1] = types
                else
                    local count = inp:isItemCount() == true
                    local destroy = false
                    pcall(function() destroy = inp:isDestroy() == true end)
                    local uses = (not count) and (not destroy) and drainableScript(firstScript)
                    local n = count and inp:getIntAmount() or math.ceil(tonumber(inp:getAmount()) or 1)
                    out.items[#out.items + 1] = { types = types, n = math.max(1, math.floor(n)), uses = uses or nil }
                end
            end
        end
        c = out
    end)
    if c == nil and G.FALLBACK[name] then c = G.FALLBACK[name] end
    G.costCache[name] = c
    return c
end
-- a stage's word list of what it needs: "2 planks, 4 nails"
function G.itemWord(fullType)
    local s = tostring(fullType)
    local nm = nil
    pcall(function() local sc = getScriptManager():FindItem(s); if sc then nm = sc:getDisplayName() end end)
    return nm or (string.match(s, "%.(.+)$") or s)
end
function G.needText(need)
    local parts = {}
    for _, e in ipairs(need or {}) do
        local w = G.itemWord(e.types and e.types[1] or e.type)
        if e.uses then parts[#parts + 1] = tostring(e.n) .. " uses of " .. w else parts[#parts + 1] = tostring(e.n) .. " " .. w end
    end
    return table.concat(parts, ", ")
end
-- what's still to build for a plan (this stage on): { key -> { types, n, uses } } summed
function G.remaining(plan, into)
    into = into or {}
    local t = G.TYPES[plan.type]
    if t == nil or plan.kind == "down" then return into end
    for s = math.max(1, tonumber(plan.stage) or 1), #t.stages do
        local c = G.costOf(t.stages[s])
        for _, e in ipairs(c and c.items or {}) do
            local key = tostring(e.types[1]) .. (e.uses and "#u" or "")
            local have = into[key]
            if have == nil then have = { types = e.types, n = 0, uses = e.uses }; into[key] = have end
            have.n = have.n + e.n
        end
    end
    return into
end

----------------------------------------------------------------------------------------------------------------
-- 0.9.0.1: everything vanilla builds
----------------------------------------------------------------------------------------------------------------
-- the name vanilla's build menu shows (ISEntityBuildMenu.buildCategoryMenu: the UiConfig skin's entity style)
function G.labelOf(info)
    local label = nil
    pcall(function()
        local ui = info:getScript():getParent():getComponentScriptFor(ComponentType.UiConfig)
        if ui then
            local skin = XuiManager.GetSkin(ui:getXuiSkinName()) or XuiManager.GetDefaultSkin()
            local style = skin and skin:getEntityUiStyle(ui:getEntityStyle())
            if style and style:getDisplayName() then label = style:getDisplayName() end
        end
    end)
    if label == nil then pcall(function() label = info:getRecipe():getCraftRecipe():getTranslationName() end) end
    if label == nil or label == "" then pcall(function() label = info:getName() end) end
    return tostring(label or "?")
end
function G.catOf(info)
    local c = nil
    pcall(function() c = info:getRecipe():getBuildCategory() end)
    if c == nil or c == "" then return "Other" end
    local t = nil
    pcall(function() t = getText(c) end)
    return tostring(t or c)
end
-- stages from bare ground: walk the script's previous stages back (ISBuildIsoEntity: a stage can only go up on a
-- previous one). Nil = can't be started from nothing with what's in the list.
function G.chainOf(info, byName)
    local chain = { info:getName() }
    local cur = info
    for _ = 1, 6 do
        local prev = nil
        pcall(function() prev = cur:getScript():getPreviousStages() end)
        local n = 0
        pcall(function() n = prev and prev:size() or 0 end)
        if n == 0 then return chain end
        local found = nil
        for k = 0, n - 1 do
            local nm = nil
            pcall(function() nm = string.lower(tostring(prev:get(k))) end)
            if nm and byName[nm] then found = byName[nm]; break end
        end
        if found == nil then return nil end
        for _, x in ipairs(chain) do if x == found:getName() then return nil end end -- a loop
        table.insert(chain, 1, found:getName())
        cur = found
    end
    return nil
end
G.CATS = G.CATS or {}
function G.loadCatalog(force)
    if G.catalogDone and not force then return G.catalogN or 0 end
    if G.setting("ghostAllVanilla") == false then return 0 end
    local infos = nil
    if fn(ISBuildIsoEntity, "GetAllBuildableEntities") then pcall(function() infos = ISBuildIsoEntity.GetAllBuildableEntities() end) end
    if infos == nil then
        infos = {}
        pcall(function()
            local all = SpriteConfigManager.GetObjectInfoList()
            for i = 0, all:size() - 1 do
                local info = all:get(i)
                if info:getScript() and info:getRecipe() then infos[#infos + 1] = info end
            end
        end)
    end
    if #infos == 0 then return 0 end -- not ready yet (try again later)
    local byName, finals = {}, {}
    for _, info in ipairs(infos) do pcall(function() byName[string.lower(info:getName())] = info; G.infoCache[info:getName()] = info end) end
    for _, id in ipairs(G.ORDER) do local t = G.TYPES[id]; if t and t.basic then finals[t.stages[#t.stages]] = true end end
    local n = 0
    for _, info in ipairs(infos) do
        pcall(function()
            local name = info:getName()
            if finals[name] or G.TYPES["e:" .. name] then return end
            local chain = G.chainOf(info, byName)
            if chain == nil then return end
            for _, st in ipairs(chain) do local c = G.costOf(st); if c == nil or c.unsupported then return end end
            local cat = G.catOf(info)
            local label = G.labelOf(info)
            G.register({ id = "e:" .. name, label = label, word = string.lower(label), cat = cat, stages = chain, entity = true,
                icon = (function() local s = nil; pcall(function() s = info:getMainSpriteNameUI() end); return s end)() })
            if G.CATS[cat] == nil then G.CATS[cat] = {} end
            table.insert(G.CATS[cat], "e:" .. name)
            n = n + 1
        end)
    end
    G.catalogDone, G.catalogN = true, n
    log("catalog: " .. n .. " vanilla buildables on top of the " .. G.BASIC_COUNT .. " basic types")
    return n
end
-- the categories, sorted, each with its ids sorted by label
function G.catList()
    G.loadCatalog()
    local out = {}
    for cat, ids in pairs(G.CATS) do
        table.sort(ids, function(a, b) return tostring(G.TYPES[a].label) < tostring(G.TYPES[b].label) end)
        out[#out + 1] = { cat = cat, ids = ids }
    end
    table.sort(out, function(a, b) return a.cat < b.cat end)
    return out
end
function G.typeOf(id)
    id = tostring(id or "")
    if G.TYPES[id] == nil and string.sub(id, 1, 2) == "e:" then G.loadCatalog() end
    return G.TYPES[id]
end

----------------------------------------------------------------------------------------------------------------
-- the queue (global ModData: saved with the world, shared in multiplayer)
----------------------------------------------------------------------------------------------------------------
function G.store()
    local d = nil
    pcall(function() d = ModData.getOrCreate(G.MODDATA) end)
    if type(d) ~= "table" then G._mem = G._mem or {}; d = G._mem end
    d.seq = tonumber(d.seq) or 0
    d.list = type(d.list) == "table" and d.list or {}
    d.layouts = type(d.layouts) == "table" and d.layouts or {}
    d.piles = type(d.piles) == "table" and d.piles or {}
    return d
end
function G.byId(id)
    for i, p in ipairs(G.store().list) do if p.id == id then return p, i end end
    return nil
end
function G.at(x, y, z)
    for _, p in ipairs(G.store().list) do if p.x == x and p.y == y and p.z == z then return p end end
    return nil
end
local function transmit()
    if type(ModData) == "table" and fn(ModData, "transmit") and ALifeSide.server() then pcall(ModData.transmit, G.MODDATA) end
end
G.transmit = transmit
local function playerKey(p)
    local k = nil
    pcall(function() k = p:getUsername() end)
    if k == nil or k == "" then pcall(function() k = "p" .. tostring(p:getPlayerNum()) end) end
    return tostring(k or "p0")
end
G.playerKey = playerKey

-- who may change the plans: single player always; multiplayer: setting ghostLeaderOnly (the first who placed one
-- = the base's owner) else anyone
function G.mayEdit(player)
    if ALifeSide.ui() then return true end
    if G.setting("ghostLeaderOnly") ~= true then return true end
    local d = G.store()
    return d.owner == nil or d.owner == playerKey(player)
end
-- inside the base? G.baseOf(player) is set by the client (A-Life's base mark / the safehouse); without it (a server
-- that can't see the base) only the range counts
function G.inBase(player, x, y)
    if not fn(G, "baseOf") then return true end
    local b = nil
    pcall(function() b = G.baseOf(player) end)
    if b == nil then return false end
    local pad = G.num("ghostBaseTiles")
    return x >= b.x1 - pad and x <= b.x2 + pad and y >= b.y1 - pad and y <= b.y2 + pad
end
-- a new plan (server side). Returns plan or nil, why.
function G.place(player, a)
    if G.setting("ghostBuild") == false then return nil, "off" end
    if type(a) ~= "table" then return nil, "bad" end
    local t = G.typeOf(a.type)
    if t == nil then return nil, "type" end
    local x, y, z = math.floor(tonumber(a.x) or -1), math.floor(tonumber(a.y) or -1), math.floor(tonumber(a.z) or 0)
    if x < 0 or y < 0 or z < 0 or z > 7 then return nil, "bad" end
    if not G.mayEdit(player) then return nil, "leader" end
    local px, py = nil, nil
    pcall(function() px, py = player:getX(), player:getY() end)
    local r = G.num("ghostRange")
    if px == nil or (px - x) ^ 2 + (py - y) ^ 2 > r * r then return nil, "far" end
    if G.setting("ghostOutside") ~= true and not G.inBase(player, x, y) then return nil, "outside" end
    local d = G.store()
    if #d.list >= G.num("ghostMax") then return nil, "full" end
    local nSprite = math.floor(tonumber(a.nSprite) or 1)
    for _, p in ipairs(d.list) do if p.x == x and p.y == y and p.z == z and p.nSprite == nSprite and p.kind ~= "down" then return nil, "taken" end end
    d.seq = d.seq + 1
    if d.owner == nil then d.owner = playerKey(player) end
    local plan = { id = "g" .. d.seq, type = t.id, stage = 1, x = x, y = y, z = z, nSprite = nSprite, north = a.north == true,
        sprite = type(a.sprite) == "string" and string.sub(a.sprite, 1, 80) or nil, by = playerKey(player), h = hours(),
        state = "waiting", why = nil, need = nil, work = 0, builder = nil, hooks = {} }
    d.list[#d.list + 1] = plan
    transmit()
    return plan
end
-- a line or a box: cells = { { x, y, z, nSprite, sprite } ... }, one type. Returns how many, the last why
function G.placeMany(player, a)
    if type(a) ~= "table" or type(a.cells) ~= "table" then return 0, "bad" end
    local n, why = 0, nil
    local maxN = G.num("ghostLineMax")
    for i, c in ipairs(a.cells) do
        if i > maxN then why = "line"; break end
        if type(c) == "table" then
            local p, w = G.place(player, { type = a.type, x = c.x, y = c.y, z = c.z or a.z, nSprite = c.nSprite or a.nSprite, north = c.north, sprite = c.sprite })
            if p then n = n + 1 else why = w end
        end
    end
    return n, why
end
function G.cancel(player, id)
    if not G.mayEdit(player) then return false, "leader" end
    local p, i = G.byId(tostring(id or ""))
    if p == nil then return false, "gone" end
    table.remove(G.store().list, i)
    transmit()
    return true -- nothing is lost: materials are only taken when a stage is finished; a finished frame stays
end
function G.move(player, id, dir)
    if not G.mayEdit(player) then return false, "leader" end
    local list = G.store().list
    local _, i = G.byId(tostring(id or ""))
    if i == nil then return false, "gone" end
    local j = i + ((tonumber(dir) or 0) < 0 and -1 or 1)
    if j < 1 or j > #list then return false, "edge" end
    list[i], list[j] = list[j], list[i]
    transmit()
    return true
end
-- who builds it (uid of a settler) or nil = anyone
function G.assign(player, id, who)
    if not G.mayEdit(player) then return false, "leader" end
    local p = G.byId(tostring(id or ""))
    if p == nil then return false, "gone" end
    if who == nil or who == "" then p.who, p.whoAt = nil, nil else p.who, p.whoAt = string.sub(tostring(who), 1, 60), hours() end
    p.retryAt = nil
    transmit()
    return true
end
-- take this down: a dismantlable object (IsoThumpable:isDismantable, as vanilla's ISDestroyCursor checks it on the
-- client) at x,y,z, named; the builders dismantle it like vanilla's ISDismantleAction (a saw and a screwdriver)
function G.markDown(player, a)
    if G.setting("ghostBuild") == false then return nil, "off" end
    if type(a) ~= "table" then return nil, "bad" end
    if not G.mayEdit(player) then return nil, "leader" end
    local x, y, z = math.floor(tonumber(a.x) or -1), math.floor(tonumber(a.y) or -1), math.floor(tonumber(a.z) or 0)
    if x < 0 or y < 0 or z < 0 or z > 7 then return nil, "bad" end
    local px, py = nil, nil
    pcall(function() px, py = player:getX(), player:getY() end)
    local r = G.num("ghostRange")
    if px == nil or (px - x) ^ 2 + (py - y) ^ 2 > r * r then return nil, "far" end
    if G.setting("ghostOutside") ~= true and not G.inBase(player, x, y) then return nil, "outside" end
    local d = G.store()
    if #d.list >= G.num("ghostMax") then return nil, "full" end
    local name = string.sub(tostring(a.name or ""), 1, 80)
    for _, p in ipairs(d.list) do if p.kind == "down" and p.x == x and p.y == y and p.z == z and p.obj == name then return nil, "taken" end end
    d.seq = d.seq + 1
    local plan = { id = "g" .. d.seq, kind = "down", type = "down", obj = name, label = string.sub(tostring(a.label or name), 1, 60), north = a.north == true,
        sprite = type(a.sprite) == "string" and string.sub(a.sprite, 1, 80) or nil,
        stage = 1, x = x, y = y, z = z, nSprite = 0, by = playerKey(player), h = hours(), state = "waiting", work = 0, hooks = {} }
    d.list[#d.list + 1] = plan
    transmit()
    return plan
end
-- a building stockpile (a container people may haul materials from): toggles; up to 20
function G.pile(player, a)
    if type(a) ~= "table" then return false, "bad" end
    if not G.mayEdit(player) then return false, "leader" end
    local x, y, z = math.floor(tonumber(a.x) or -1), math.floor(tonumber(a.y) or -1), math.floor(tonumber(a.z) or 0)
    if x < 0 or y < 0 then return false, "bad" end
    local piles = G.store().piles
    for i, p in ipairs(piles) do if p.x == x and p.y == y and p.z == z then table.remove(piles, i); transmit(); return true, "off" end end
    if #piles >= 20 then return false, "full" end
    piles[#piles + 1] = { x = x, y = y, z = z, name = string.sub(tostring(a.name or "stockpile"), 1, 40) }
    transmit()
    return true, "on"
end
-- saved layouts: the plans within `radius` of (cx,cy) as offsets; stamp them down somewhere else
function G.saveLayout(player, a)
    if type(a) ~= "table" then return false, "bad" end
    if not G.mayEdit(player) then return false, "leader" end
    local d = G.store()
    if #d.layouts >= G.num("ghostLayoutsMax") then return false, "full" end
    local cx, cy, cz = math.floor(tonumber(a.x) or 0), math.floor(tonumber(a.y) or 0), math.floor(tonumber(a.z) or 0)
    local r = math.max(1, math.min(60, tonumber(a.radius) or 20))
    local cells = {}
    for _, p in ipairs(d.list) do
        if p.kind ~= "down" and (p.x - cx) ^ 2 + (p.y - cy) ^ 2 <= r * r and #cells < 200 then
            cells[#cells + 1] = { type = p.type, dx = p.x - cx, dy = p.y - cy, dz = p.z - cz, nSprite = p.nSprite, sprite = p.sprite }
        end
    end
    if #cells == 0 then return false, "empty" end
    local name = string.sub(tostring(a.name or ""), 1, 40)
    if name == "" then name = "Layout " .. (#d.layouts + 1) end
    d.layouts[#d.layouts + 1] = { name = name, cells = cells, by = playerKey(player) }
    transmit()
    return true, name
end
function G.stamp(player, a)
    if type(a) ~= "table" then return 0, "bad" end
    local l = G.store().layouts[math.floor(tonumber(a.index) or 0)]
    if l == nil then return 0, "gone" end
    local x, y, z = math.floor(tonumber(a.x) or 0), math.floor(tonumber(a.y) or 0), math.floor(tonumber(a.z) or 0)
    local n, why = 0, nil
    for _, c in ipairs(l.cells) do
        local p, w = G.place(player, { type = c.type, x = x + c.dx, y = y + c.dy, z = z + (c.dz or 0), nSprite = c.nSprite, sprite = c.sprite })
        if p then n = n + 1 else why = w end
    end
    return n, why
end
function G.delLayout(player, index)
    if not G.mayEdit(player) then return false, "leader" end
    local l = G.store().layouts
    local i = math.floor(tonumber(index) or 0)
    if l[i] == nil then return false, "gone" end
    table.remove(l, i)
    transmit()
    return true
end
-- the plan as sent to clients (plain table)
function G.view(p)
    local t = G.TYPES[p.type] or {}
    local label = t.label or p.type
    if p.kind == "down" then label = "Take down: " .. tostring(p.label or p.obj or "?") end
    return { id = p.id, type = p.type, kind = p.kind, label = label, stage = p.stage, stages = t.stages and #t.stages or 1, x = p.x, y = p.y, z = p.z,
        nSprite = p.nSprite, sprite = p.sprite, state = p.state, why = p.why, need = p.need, needText = (type(p.need) == "table" and #p.need > 0) and G.needText(p.need) or nil, builder = p.builder, helper = p.helper, who = p.who, work = p.work, obj = p.obj }
end
function G.list()
    local out = {}
    for _, p in ipairs(G.store().list) do out[#out + 1] = G.view(p) end
    return out
end
function G.layoutNames()
    local out = {}
    for i, l in ipairs(G.store().layouts) do out[#out + 1] = { index = i, name = l.name, n = #l.cells } end
    return out
end

function G.install()
    if G.installed or not fn(ALifeCmd, "onServer") then return G.installed == true end
    local function answer(player, ok, why, extra)
        local d = G.store()
        ALifeCmd.reply(player, "ghostList", { ok = ok, why = why, extra = extra, list = G.list(), layouts = G.layoutNames(), piles = d.piles })
    end
    local function A(a) return type(a) == "table" and a or {} end
    ALifeCmd.onServer("ghostAsk", function(player, a) answer(player, true) end)
    ALifeCmd.onServer("ghostPlace", function(player, a)
        local p, why = G.place(player, a)
        answer(player, p ~= nil, why)
    end)
    ALifeCmd.onServer("ghostPlaceMany", function(player, a) local n, why = G.placeMany(player, a); answer(player, n > 0, (n == 0) and why or nil, n) end)
    ALifeCmd.onServer("ghostCancel", function(player, a) local ok, why = G.cancel(player, A(a).id); answer(player, ok, why) end)
    ALifeCmd.onServer("ghostMove", function(player, a) local ok, why = G.move(player, A(a).id, A(a).dir); answer(player, ok, why) end)
    ALifeCmd.onServer("ghostAssign", function(player, a) local ok, why = G.assign(player, A(a).id, A(a).who); answer(player, ok, why) end)
    ALifeCmd.onServer("ghostDown", function(player, a) local p, why = G.markDown(player, a); answer(player, p ~= nil, why) end)
    ALifeCmd.onServer("ghostPile", function(player, a) local ok, why = G.pile(player, a); answer(player, ok, ok and nil or why, why) end)
    ALifeCmd.onServer("ghostSaveLayout", function(player, a) local ok, why = G.saveLayout(player, a); answer(player, ok, ok and nil or why, why) end)
    ALifeCmd.onServer("ghostStamp", function(player, a) local n, why = G.stamp(player, a); answer(player, n > 0, (n == 0) and why or nil, n) end)
    ALifeCmd.onServer("ghostDelLayout", function(player, a) local ok, why = G.delLayout(player, A(a).index); answer(player, ok, why) end)
    G.installed = true
    return true
end
G.install()
print(TAG .. " ready v" .. G.VERSION .. ": " .. #G.ORDER .. " basic types + every vanilla buildable (catalog loads at first use); lines / boxes, take down, stockpiles, layouts, assign")
return G
