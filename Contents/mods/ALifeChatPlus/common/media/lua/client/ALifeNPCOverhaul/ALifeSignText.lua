-- A-Life NPC Overhaul: floating text over territory signs, readable from a distance.
-- A cache of nearby signs is rebuilt every few seconds (cheap); drawing each frame just walks the cache.
local TAG = "[ALifeSignText]"
ALifeSignText = ALifeSignText or {}
local S = ALifeSignText
S.RANGE = 30          -- tiles
S.SCAN_MS = 4000      -- rescan interval
S.cache, S.lastScan = {}, -1e9

local function nowMs() return type(getTimestampMs) == "function" and getTimestampMs() or 0 end
local function eachOf(coll, fn)
    if coll == nil then return end
    -- index first: PZArrayList (square objects) throws on iterator() and spams the error log
    local ok = pcall(function() for i = 0, coll:size() - 1 do fn(coll:get(i)) end end)
    if ok then return end
    pcall(function() local it = coll:iterator(); while it:hasNext() do fn(it:next()) end end)
end

-- the words on a sign item, or nil if it isn't one
function S.textOf(item)
    local ok, md = pcall(function() return item:getModData() end)
    if not ok or type(md) ~= "table" or not md.ALifeSign then return nil end
    if type(md.ALifeSignText) == "string" and md.ALifeSignText ~= "" then return md.ALifeSignText end
    local n = item:getName()
    return n and string.gsub(n, "^Sign:%s*", "") or nil
end

-- the words on a sign tile, or nil
function S.tileText(obj)
    local ok, md = pcall(function() return obj:getModData() end)
    if not ok or type(md) ~= "table" or not md.ALifeSign then return nil end
    if type(md.ALifeSignText) == "string" and md.ALifeSignText ~= "" then return md.ALifeSignText end
    return nil
end

function S.scan(player)
    local out, cell = {}, getCell()
    if cell == nil then S.cache = out return end
    local px, py, pz = math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
    local R = S.RANGE
    for x = px - R, px + R do
        for y = py - R, py + R do
            local sq = cell:getGridSquare(x, y, pz)
            if sq ~= nil then
                eachOf(sq:getWorldObjects(), function(wo)
                    local text = S.textOf(wo:getItem())
                    if text then out[#out + 1] = { x = x + 0.5, y = y + 0.5, z = pz, text = string.upper(text) } end
                end)
                -- sign tiles (alife_signs_01): only objects that already carry ModData, so we never create tables
                eachOf(sq:getObjects(), function(o)
                    local has = false
                    pcall(function() has = o:hasModData() end)
                    if has then
                        local text = S.tileText(o)
                        if text then out[#out + 1] = { x = x + 0.5, y = y + 0.5, z = pz, text = string.upper(text) } end
                    end
                end)
            end
        end
    end
    S.cache = out
end

-- world position -> screen pixels (UI space)
local function toScreen(x, y, z, pn, player)
    -- world -> screen at zoom 1, minus the camera, then scaled by the current zoom so it tracks zooming
    local ok, sx, sy = pcall(function()
        local zoom = getCore():getZoom(pn)
        local wx = IsoUtils.XToScreen(x, y, z, 0) - IsoCamera.getOffX()
        local wy = IsoUtils.YToScreen(x, y, z, 0) - IsoCamera.getOffY()
        return wx / zoom, wy / zoom
    end)
    if ok and sx and sy then return sx, sy end
    return nil
end

function S.draw()
    local player = getPlayer and getPlayer()
    if player == nil then return end
    local t = nowMs()
    if t - S.lastScan >= S.SCAN_MS then
        S.lastScan = t
        local ok, err = pcall(S.scan, player)
        if not ok and not S.warned then S.warned = true; print(TAG .. " scan failed: " .. tostring(err)) end
    end
    if #S.cache == 0 then return end
    local pn = player:getPlayerNum()
    local tm = getTextManager()
    for _, e in ipairs(S.cache) do
        local d = math.sqrt((e.x - player:getX()) ^ 2 + (e.y - player:getY()) ^ 2)
        local sx, sy = toScreen(e.x, e.y, e.z, pn, player)
        if sx and d <= S.RANGE then
            local a = d <= 10 and 1 or (1 - 0.5 * (d - 10) / (S.RANGE - 10))
            local w = tm:MeasureStringX(UIFont.Small, e.text) + 12
            local h = tm:getFontHeight(UIFont.Small) + 6
            local x, y = sx - w / 2, sy - 56
            pcall(function() getRenderer():renderRect(x, y, w, h, 0.05, 0.05, 0.05, 0.7 * a) end)
            tm:DrawStringCentre(UIFont.Small, sx + 1, y + 4, e.text, 0, 0, 0, a)
            tm:DrawStringCentre(UIFont.Small, sx, y + 3, e.text, 0.95, 0.85, 0.75, a)
        end
    end
end

if Events ~= nil and Events.OnPostUIDraw ~= nil then
    ALifeHealth.add(Events.OnPostUIDraw, "ALifeSignText", function()
        local ok, err = pcall(S.draw)
        if not ok and not S.drawWarned then S.drawWarned = true; print(TAG .. " draw failed: " .. tostring(err)) end
    end)
end
print(TAG .. " loaded")
