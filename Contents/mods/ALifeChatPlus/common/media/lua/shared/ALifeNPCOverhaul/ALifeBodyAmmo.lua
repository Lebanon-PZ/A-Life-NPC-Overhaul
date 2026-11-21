-- A-Life NPC Overhaul pre-1.0: AMMO ON THE DEAD + GUN CARRIERS WANT SPARE MAGS.
-- Players found no ammo on dead NPCs. Read in A-Life 1.5.1 (server/ProjectALife/Shells/ALifeDeathDrops.lua):
--   * spare ammo is a NUMBER in the shell's modData (Project<Slot>AmmoUnits), never items (Combat/ALifeWeapons.lua);
--   * on death DeathDrops.dropMagazines drops real filled magazines, but ONLY for the guns in plan.weaponTypes (the
--     profile's authored guns) and only as many as the authored plan.ammo says. A gun picked up later (ModLoot swap,
--     modded gun, scavenged, handed over) and ammo found on a scavenge run (credited to the number) never reached the
--     body; plan.magazineMax defaults to 1 mag and each mag rolls ~35%.
-- Here: wrap dropMagazines. The plan it sees is rebuilt from what the body really had: the gun actually in the pack
-- (its own magazine type, modded too) and the real reserve (plan.carried, A-Life's honest-ammo count). A-Life's own code
-- then drops the filled mags (wear, BalancePass veto, honest cap all intact). Nothing is created beyond what they carried.
-- Also: someone carrying a gun with fewer than ammoWantMags spare mags goes looking for ammo on a scavenge run
-- (A-Life picks "what the group wants" by a hash of the group id; ours says ammo when it is true). Found ammo is
-- credited to the reserve by A-Life, and now reaches the body on death.
-- REAL MAGS (guns that take a magazine only; revolvers, shotguns, bolt guns keep rounds): A-Life keeps spare ammo as a
-- number and "reloads" by subtracting it. Here the boxed part becomes real filled magazine items in the pack
-- (B.pack: the number goes down by exactly what became mags, nothing is added), flagged ProjectALifeScavenged so A-Life's
-- ShellState carries them (with their rounds) through dormancy. A reload (Magazines.beginReload/commitReload wrapped) swaps a
-- real mag into the gun; the old one stays in the pack with what was left in it. No mag in the pack: A-Life's own path
-- (loose rounds, i.e. filling a mag). Dead: A-Life's own item thinning applies to the mags in the pack.
-- Settings: packMags, packMagsMax, bodyAmmo, bodyAmmoMags (most mags per gun), bodyAmmoChance (% per mag), ammoWant, ammoWantMags.
require "ALifeNPCOverhaul/AA_Side"
ALifeBodyAmmo = ALifeBodyAmmo or {}
local B = ALifeBodyAmmo
local TAG = "[ALifeBodyAmmo]"
B.VERSION = ALifeSide.MOD_VERSION
B.metrics = B.metrics or { plans = 0, patched = 0, wanted = 0 }
B.DEFAULTS = {
    bodyAmmo = true,        -- the dead drop their real spare ammo for the gun they really carried
    bodyAmmoMags = 3,       -- most spare mags dropped per gun (A-Life's own default is 1)
    bodyAmmoChance = 70,    -- chance (pct) each of those mags is still there (A-Life's own is about 35)
    ammoWant = true,        -- gun carriers short of spare mags look for ammo first on a scavenge run
    ammoWantMags = 3,       -- spare mags they want (never more than A-Life's reserve cap allows)
    packMags = true,        -- guns that take a magazine: spare ammo is carried as real filled mags; a reload swaps a real mag
    packMagsMax = 4,        -- most real spare mags in the pack per gun (the rest stays loose rounds)
}
B.FILE_KEYS = {}
for k in pairs(B.DEFAULTS) do B.FILE_KEYS[#B.FILE_KEYS + 1] = k end
table.sort(B.FILE_KEYS)

local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function log(m) print(TAG .. " " .. tostring(m)) end
local function num(v, d) v = tonumber(v); if v == nil or v ~= v then return d end return v end
function B.setting(key)
    local m = ALifeLLMTalk
    local v = nil
    if type(m) == "table" and type(m.settings) == "table" then v = m.settings[key] end
    if v == nil then v = B.DEFAULTS[key] end
    return v
end
function B.n(key) return num(B.setting(key), num(B.DEFAULTS[key], 0)) end
function B.on(key) return B.setting(key) ~= false end
local function ask(o, m, ...) if o == nil then return nil end local ok, v = pcall(function(...) return o[m](o, ...) end, ...); if ok then return v end return nil end

-- ---------------------------------------------------------------- the dead
-- the plan A-Life should have had: the guns in the pack, the reserve they had
function B.patchPlan(inventory, plan)
    local pa = PA()
    if type(plan) ~= "table" or type(plan.carried) ~= "table" or inventory == nil or not fn(pa and pa.Weapons, "slot") then return nil end
    local list = ask(inventory, "getItems")
    local size = list ~= nil and num(ask(list, "size"), 0) or 0
    local types, ammo, mode, found = {}, {}, {}, false
    for k, v in pairs(plan.weaponTypes or {}) do types[k] = v end
    for k, v in pairs(plan.ammo or {}) do ammo[k] = v end
    for k, v in pairs(plan.ammoMode or {}) do mode[k] = v end
    for i = 0, size - 1 do
        local it = ask(list, "get", i)
        if it ~= nil and ask(it, "IsWeapon") == true and ask(it, "isRanged") == true then
            local okS, slot = pcall(pa.Weapons.slot, it)
            local full = ask(it, "getFullType")
            if okS and (slot == "primary" or slot == "secondary") and type(full) == "string" and num(plan.carried[slot], 0) > 0 then
                types[slot], ammo[slot], mode[slot] = full, num(plan.carried[slot], 0), "rounds"
                found = true
            end
        end
    end
    if not found then return nil end
    local p = {}
    for k, v in pairs(plan) do p[k] = v end
    p.weaponTypes, p.ammo, p.ammoMode = types, ammo, mode
    p.dropAmmo = true
    p.magazineMax = math.max(num(plan.magazineMax, 0), math.floor(B.n("bodyAmmoMags")))
    p.magazineChance = math.max(num(plan.magazineChance, 0), math.min(100, B.n("bodyAmmoChance")))
    return p
end

-- A-Life 1.5.3 drops bonus loose rounds right after the mags (DeathDrops.dropLooseRounds), capped by the reserve left
-- after the mag drops (plan.roundsLeft, written by dropMagazines via noteLeft; experiment ammodrop_honest_loose).
-- dropMagazines saw our copy, so the left-over count and the real gun go back to A-Life's plan. Without this the loose
-- rounds were capped by the full reserve again (same ammo counted twice) and keyed to the authored gun.
-- dropAmmo is NOT handed back: the profile's own drop-ammo switch still decides the bonus loose rounds.
function B.handBack(plan, p)
    if type(plan) ~= "table" or type(p) ~= "table" then return end
    if type(p.roundsLeft) == "table" then plan.roundsLeft = p.roundsLeft end
    if type(p.weaponTypes) == "table" then plan.weaponTypes = p.weaponTypes end
end

function B.installDead()
    if B.deadInstalled then return true end
    local pa = PA()
    local DD = pa and pa.DeathDrops
    if not fn(DD, "dropMagazines") then return false end
    B.deadInstalled = true
    local orig = DD.dropMagazines
    B.origDrop = orig
    DD.dropMagazines = function(inventory, plan, ...)
        B.metrics.plans = B.metrics.plans + 1
        if B.on("bodyAmmo") then
            local ok, p = pcall(B.patchPlan, inventory, plan)
            if ok and p ~= nil then
                B.metrics.patched = B.metrics.patched + 1
                local r = orig(inventory, p, ...)
                B.handBack(plan, p)
                return r
            end
            if not ok then log("plan error: " .. tostring(p)) end
        end
        return orig(inventory, plan, ...)
    end
    return true
end

-- ---------------------------------------------------------------- real mags in the pack
local function magTypeOf(gun)
    local t = ask(gun, "getMagazineType")
    if t == nil then return nil end
    t = tostring(t)
    if t == "" or t == "null" then return nil end
    return t
end
local function packItems(shell)
    local inv = ask(shell, "getInventory")
    local list = inv ~= nil and ask(inv, "getItems") or nil
    local size = list ~= nil and num(ask(list, "size"), 0) or 0
    local out = {}
    for i = 0, size - 1 do out[#out + 1] = ask(list, "get", i) end
    return out, inv
end
local function roundsOf(it) return num(ask(it, "getCurrentAmmoCount"), 0) end
function B.realMags(shell, magType)
    local out = {}
    for _, it in ipairs((packItems(shell))) do
        if ask(it, "getFullType") == magType then out[#out + 1] = it end
    end
    return out
end
function B.bestMag(shell, gun)
    local t = magTypeOf(gun)
    if t == nil then return nil end
    local best, n = nil, 0
    for _, it in ipairs(B.realMags(shell, t)) do
        local r = roundsOf(it)
        if r > n then best, n = it, r end
    end
    return best, n
end
function B.realRounds(shell, gun)
    local t = magTypeOf(gun)
    if t == nil then return 0 end
    local n = 0
    for _, it in ipairs(B.realMags(shell, t)) do n = n + roundsOf(it) end
    return n
end
-- boxed reserve -> real filled mags (conserves rounds: the number drops by exactly what became mags)
function B.pack(shell)
    local pa = PA()
    local M, W = pa and pa.MagazineState, pa and pa.Weapons
    if not B.on("packMags") or not (fn(M, "reserve") and fn(M, "maximum") and fn(W, "slot")) then return 0 end
    if fn(M, "isInfinite") and M.isInfinite(shell) == true then return 0 end
    local made = 0
    local items, inv = packItems(shell)
    local data = ask(shell, "getModData")
    if type(data) ~= "table" or inv == nil then return 0 end
    for _, gun in ipairs(items) do
        local mt = ask(gun, "IsWeapon") == true and ask(gun, "isRanged") == true and magTypeOf(gun) or nil
        local slot = mt ~= nil and W.slot(gun) or nil
        if mt ~= nil and (slot == "primary" or slot == "secondary") then
            local cap = num(M.maximum(gun), 0)
            local res = num(M.reserve(shell, slot, gun), 0)
            local have = #B.realMags(shell, mt)
            local n = math.min(math.floor(res / math.max(1, cap)), math.max(0, math.floor(B.n("packMagsMax")) - have))
            local k = 0
            while cap > 0 and k < n do
                local ok, it = pcall(function() return inv:AddItem(mt) end)
                if not ok or it == nil then break end
                pcall(function() it:setCurrentAmmoCount(cap) end)
                pcall(function() it:getModData().ProjectALifeScavenged = true end) -- ShellState keeps it (and its rounds)
                k = k + 1
            end
            if k > 0 then
                data[slot == "secondary" and "ProjectALifeSecondaryAmmoUnits" or "ProjectALifePrimaryAmmoUnits"] = res - k * cap
                M.reserve(shell, slot, gun) -- A-Life re-normalises its own mag / loose split
                made = made + k
            end
        end
    end
    B.metrics.packed = (B.metrics.packed or 0) + made
    return made
end

function B.installPack()
    if B.packInstalled then return true end
    local pa = PA()
    local M = pa and pa.MagazineState
    if not (fn(M, "beginReload") and fn(M, "commitReload") and fn(M, "canReload") and fn(M, "current")) then return false end
    B.packInstalled = true
    local oBegin, oCommit, oCan = M.beginReload, M.commitReload, M.canReload
    M.beginReload = function(shell, item, ...)
        if B.on("packMags") and shell ~= nil and item ~= nil and magTypeOf(item) ~= nil then
            pcall(B.pack, shell)
            local mag, n = B.bestMag(shell, item)
            local cap, cur = num(M.maximum(item), 0), num(M.current(item), 0)
            if mag ~= nil and cap > 0 and cur < cap and n > cur then
                local slot = fn(pa.Weapons, "slot") and pa.Weapons.slot(item) or "primary"
                B.metrics.swaps = (B.metrics.swaps or 0) + 1
                return { shell = shell, item = item, slot = slot, capacity = cap, rounds = n, infinite = false, external = true,
                    internal = false, committed = false, mag = mag }
            end
        end
        return oBegin(shell, item, ...)
    end
    M.commitReload = function(tr, ...)
        if type(tr) == "table" and tr.mag ~= nil and not tr.committed then
            local old = num(M.current(tr.item), 0)
            local n = roundsOf(tr.mag)
            if n <= old then return false, "reload_nothing_inserted" end
            pcall(function() tr.item:setContainsClip(true) end)
            local ok = fn(M, "setLoaded") and M.setLoaded(tr.item, n)
            if not ok then return false, "reload_weapon_write_failed" end
            M.setLoaded(tr.mag, old) -- the ejected mag keeps what was left in the gun
            tr.committed, tr.loaded = true, n - old
            return true, n - old
        end
        return oCommit(tr, ...)
    end
    M.canReload = function(shell, item, ...)
        local r = oCan(shell, item, ...)
        if r == true or not B.on("packMags") or magTypeOf(item) == nil then return r end
        local mag, n = B.bestMag(shell, item)
        return mag ~= nil and n > num(M.current(item), 0)
    end
    return true
end

-- once a minute: active shells turn their boxed reserve into real mags (also after loot credited more)
function B.minute()
    local pa = PA()
    if not B.on("packMags") or not (fn(pa and pa.ActorRegistry, "each") and fn(pa.MissionService, "shellOf")) then return end
    local seen = 0
    pcall(pa.ActorRegistry.each, function(r)
        seen = seen + 1
        if seen > 300 then return true end
        if type(r) == "table" and r.lifecycle == "active" and r.uid ~= nil then
            local ok, sh = pcall(pa.MissionService.shellOf, tostring(r.uid))
            if ok and sh ~= nil then pcall(B.pack, sh) end
        end
        return false
    end)
end

-- ---------------------------------------------------------------- the living: want ammo
function B.hungry(shell)
    local pa = PA()
    if shell == nil or not (fn(pa and pa.Weapons, "current") and pa.MagazineState ~= nil) then return false end
    local M = pa.MagazineState
    local gun = pa.Weapons.current(shell)
    if gun == nil or ask(gun, "isRanged") ~= true then return false end
    local cap = num(ask(gun, "getMaxAmmo"), 0)
    if fn(M, "maximum") then cap = num(M.maximum(gun), cap) end
    if cap <= 0 then return false end
    if fn(M, "isInfinite") and M.isInfinite(shell) == true then return false end
    local slot = fn(pa.Weapons, "slot") and pa.Weapons.slot(gun) or "primary"
    if slot ~= "secondary" then slot = "primary" end
    local have = (fn(M, "reserve") and num(M.reserve(shell, slot, gun), 0) or 0) + B.realRounds(shell, gun)
    local want = math.max(0, math.floor(B.n("ammoWantMags"))) * cap
    if fn(M, "reserveCap") then
        local c = M.reserveCap(gun)
        if c ~= nil then want = math.min(want, c) end -- A-Life will not credit more than this: never chase it
    end
    return have < want
end

function B.installWant()
    if B.wantInstalled then return true end
    local pa = PA()
    local Run = pa and pa.ScavengeRun
    if not fn(Run, "wantedForActor") then return false end
    B.wantInstalled = true
    local orig = Run.wantedForActor
    Run.wantedForActor = function(actor, ...)
        if B.on("ammoWant") and type(actor) == "table" and actor.uid ~= nil then
            local shell = nil
            if fn(pa.MissionService, "shellOf") then local ok, s = pcall(pa.MissionService.shellOf, tostring(actor.uid)); if ok then shell = s end end
            local ok, h = pcall(B.hungry, shell)
            if ok and h == true then B.metrics.wanted = B.metrics.wanted + 1; return "ammo" end
        end
        return orig(actor, ...)
    end
    return true
end

function B.install()
    local a, b, c = B.installDead(), B.installWant(), B.installPack()
    if (a or b or c) and not B.said then
        B.said = true
        log("ready v" .. B.VERSION .. ": dead drop real spare ammo for the gun they carried (dead " .. tostring(a) .. ", up to "
            .. math.floor(B.n("bodyAmmoMags")) .. " mags, " .. math.floor(B.n("bodyAmmoChance")) .. "%); gun carriers want "
            .. math.floor(B.n("ammoWantMags")) .. " spare mags (hook " .. tostring(b) .. "); real mags in the pack for guns that take one, up to " .. math.floor(B.n("packMagsMax")) .. " (swap hook " .. tostring(c) .. ")")
    end
    return a and b and c
end

function B.qaLine()
    local m = B.metrics
    return "[ALIFE-QA] BodyAmmo: plans=" .. m.plans .. " patched=" .. m.patched .. " wanted=" .. m.wanted .. " packed=" .. tostring(m.packed or 0) .. " swaps=" .. tostring(m.swaps or 0)
end

if Events ~= nil then
    if Events.OnGameStart ~= nil then Events.OnGameStart.Add(function() local ok, e = pcall(B.install); if not ok then log("install failed: " .. tostring(e)) end end) end
    if Events.OnServerStarted ~= nil then Events.OnServerStarted.Add(function() pcall(B.install) end) end
    if Events.EveryOneMinute ~= nil then Events.EveryOneMinute.Add(function() pcall(B.minute) end) end
end

return B
