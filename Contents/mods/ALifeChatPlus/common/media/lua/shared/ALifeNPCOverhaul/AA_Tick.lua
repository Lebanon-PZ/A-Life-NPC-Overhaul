-- A-Life NPC Overhaul: TICK GOVERNOR. A-Life Talk had ~55 separate OnTick hooks (hundreds of Lua calls a second).
-- They now share ONE hook that runs them round-robin under a small time budget per frame. Most of them already only
-- act every N ticks, so the only effect is that background talk / mood / social checks happen a little less often.
ALifeTick = ALifeTick or { list = {}, idx = 0, budgetMs = 2, minPerTick = 3, maxPerTick = 12 }
local T = ALifeTick
local function now() return type(getTimestampMs) == "function" and getTimestampMs() or 0 end

function T.add(fn)
    if type(fn) ~= "function" then return end
    for _, f in ipairs(T.list) do if f == fn then return end end
    T.list[#T.list + 1] = fn
end

function T.remove(fn)
    for i = #T.list, 1, -1 do if T.list[i] == fn then table.remove(T.list, i) end end
end

local function run()
    local n = #T.list
    if n == 0 then return end
    local start, done = now(), 0
    while done < n and done < T.maxPerTick do
        T.idx = T.idx % n + 1
        local f = T.list[T.idx]
        if f then
            local ok, e = pcall(f)
            if not ok and not T.warned then T.warned = true; print("[ALifeNPCOverhaul] tick handler error: " .. tostring(e)) end
        end
        done = done + 1
        n = #T.list
        if done >= T.minPerTick and now() - start >= T.budgetMs then break end
    end
end

if not T.__hooked and Events and Events.OnTick then
    T.__hooked = true
    if type(ALifeHealth) == "table" then ALifeHealth.add(Events.OnTick, "background ticks (all)", run) else Events.OnTick.Add(run) end
end
