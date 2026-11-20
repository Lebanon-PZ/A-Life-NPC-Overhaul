-- A-Life NPC Overhaul 0.5.11: decimals without string.format("%.Nf"), which throws in Kahlua.
-- ALifeFmtDec(3.14159, 2) -> "3.14". Whole-number maths only (math.floor), safe anywhere.
function ALifeFmtDec(x, places)
    x = tonumber(x) or 0
    if x ~= x or x == math.huge or x == -math.huge then return "0" end
    places = math.max(0, math.floor(tonumber(places) or 0))
    local m = 1
    for _ = 1, places do m = m * 10 end
    local v = math.floor(math.abs(x) * m + 0.5)
    local i = math.floor(v / m)
    local sign = (x < 0 and v > 0) and "-" or ""
    if places == 0 then return sign .. tostring(i) end
    local f = tostring(math.floor(v - i * m))
    while #f < places do f = "0" .. f end
    return sign .. tostring(i) .. "." .. f
end

-- 0.6.8: a well-mixed dice roll in [0, 1) for a seed string. The plain string hash is nearly linear in its last
-- characters, so "group X, day N" rolls drifted day by day (a 10%-a-day event could miss for months, then hit many
-- days running). Two 16-bit quadratic mixes (exact in doubles), combined.
local function djb2(s) local h = 5381; for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end; return h end
function ALifeRoll01(seed)
    seed = tostring(seed)
    local a, b = djb2(seed) % 65521, djb2("~" .. seed) % 65519
    for _ = 1, 3 do a = (a * a + 40503) % 65521; b = (b * b + 31337) % 65519 end
    return ((a * 65519 + b) % 4294967291) / 4294967291
end
