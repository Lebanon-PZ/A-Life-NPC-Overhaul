-- A-Life NPC Overhaul 0.9.5: the loaded cell's vehicles as a plain Lua list.
-- 42.21: IsoCell.getVehicles() is a java.util.HashSet (no size()/get(i) from Lua) -> walk it with iterator()
-- (HashSet + Iterator are exposed; verified via the jar). size()/get(i) only as a fallback for builds with a list.
ALifeCellCars = ALifeCellCars or {}
function ALifeCellCars.list()
    local out = {}
    local vs = nil
    pcall(function() vs = getCell():getVehicles() end)
    if vs == nil then return out end
    local ok = pcall(function() local it = vs:iterator(); while it:hasNext() do local v = it:next(); if v ~= nil then out[#out + 1] = v end end end)
    if not ok then
        out = {}
        pcall(function() for i = 0, vs:size() - 1 do local v = vs:get(i); if v ~= nil then out[#out + 1] = v end end end)
    end
    return out
end
