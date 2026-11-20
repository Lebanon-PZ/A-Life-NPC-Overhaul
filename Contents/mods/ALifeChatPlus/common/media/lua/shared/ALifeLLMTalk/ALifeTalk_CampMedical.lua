-- ALifeTalk_CampMedical.lua (0.5.7): the sick bay and medic triage.
-- * Sick bay (Camp > Medical > Sick bay here): the hurt walk there and rest instead of working.
-- * Triage: medics go to the worst-hurt person first (bleeding > broken bones > pain), walk over if they're far,
--   and restock bandages and splints from your meds drop points when they run out.
-- Treatment itself is the patch's own medic code (P.treatOther), the same one camp medics already used.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeTalk_CampMedical") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeTalk_Camp"
local M = ALifeLLMTalk
if type(M) ~= "table" or type(M.cpAddJob) ~= "function" then return end
local H = M.cpH

M.cpDefaults.CPSickBay = true
M.mdCfg = { restMs = 240000, restAgainH = 1, reachTiles = 3, kit = 4, treatMs = 4000 }
M.mdStats = { rested = 0, treated = 0, restocked = 0 }
M.mdKit = { ["Base.Bandage"] = true, ["Base.AlcoholBandage"] = true, ["Base.RippedSheets"] = true, ["Base.AlcoholRippedSheets"] = true, ["Base.Splint"] = true }

function M.mdData()
    local d = M.cpData()
    d.med = type(d.med) == "table" and d.med or {}
    d.med.restAt = type(d.med.restAt) == "table" and d.med.restAt or {}
    return d.med
end
local function state(uid)
    if not H.fn(M, "woundState") then return nil end
    local ok, s = pcall(M.woundState, tostring(uid))
    return ok and type(s) == "table" and s or nil
end
-- how badly they need a medic (0 = fine)
function M.mdScore(uid)
    local s = state(uid)
    if s == nil or not s.hurt then return 0 end
    local v = (s.bleeding or 0) * 3 + (s.fracture and 2 or 0) + (s.downed and 5 or 0) + (tonumber(s.pain) or 0) * 3
    if tonumber(s.hp) then v = v + math.max(0, 100 - s.hp) / 25 end
    return v
end
-- something a medic can actually fix with a kit: open bleeding or an unsplinted break
function M.mdTreatable(uid) local s = state(uid); return s ~= nil and ((s.bleeding or 0) > 0 or s.fracture == true) end
-- should rest in the sick bay
function M.mdNeedsRest(uid)
    local s = state(uid)
    if s == nil or not s.hurt or s.downed then return false end
    return (s.bleeding or 0) > 0 or s.fracture or s.limp or (tonumber(s.pain) or 0) >= 0.3
end
local function kitCount(shell)
    local n = 0
    pcall(function() local items = shell:getInventory():getItems(); for i = 0, items:size() - 1 do if M.mdKit[items:get(i):getFullType()] then n = n + 1 end end end)
    return n
end
-- the worst-off patient for this medic
function M.mdPatient(medic, player)
    local best, bs = nil, 0
    for _, u in ipairs(M.cpPeople(player)) do
        if u ~= medic and M.mdTreatable(u) then
            local s = M.mdScore(u)
            if s > bs then best, bs = u, s end
        end
    end
    return best
end
-- a spot beside the sick bay (people spread around it)
local function bedSpot(uid)
    local b = M.mdData().bay
    if b == nil then return nil end
    local i = H.hash(uid) % 8
    local o = ({ { 0, 0 }, { 1, 0 }, { 0, 1 }, { 1, 1 }, { -1, 0 }, { 0, -1 }, { -1, 1 }, { 1, -1 } })[i + 1]
    return { x = b.x + o[1], y = b.y + o[2], z = b.z }
end

-- the hurt go to the sick bay and rest (before the watch: a bleeding guard doesn't stand watch)
M.cpAddJob({
    kind = "sickbay", order = -5,
    pick = function(uid, shell, player, b, now)
        if M.cpOpt("CPSickBay") == false or M.mdData().bay == nil then return nil end
        if H.fn(M, "cbKnown") and M.cbKnown(uid) then return nil end
        local last = M.mdData().restAt[uid]
        if last and H.hours() - last < M.mdCfg.restAgainH then return nil end
        if not M.mdNeedsRest(uid) then return nil end
        return { key = "sickbay:" .. uid }
    end,
    spot = function(j) return bedSpot(j.key) end,
    ms = function(j) return 1500 end,
    run = function(j, uid, shell, player)
        M.mdData().restAt[uid] = H.hours()
        local P = M.patch and M.patch() or nil
        if P and H.fn(P, "woundRest") then pcall(P.woundRest, uid, M.mdCfg.restMs, "sickbay") end
        M.mdStats.rested = M.mdStats.rested + 1
        return "done"
    end,
})

-- medics: restock, then go to the worst-hurt and treat them
M.cpAddJob({
    kind = "medic", order = -4,
    pick = function(uid, shell, player, b, now)
        if M.cpRoleOf(uid) ~= "medic" then return nil end
        local patient = M.mdPatient(uid, player)
        if patient == nil then return nil end
        if kitCount(shell) == 0 then
            local drops = M.cpData().drops.meds or {}
            for _, p in ipairs(drops) do
                local sq = H.sqAt(p.x, p.y, p.z)
                local c = sq and H.containerOn(sq)
                local has = false
                if c then pcall(function() local items = c:getItems(); for i = 0, items:size() - 1 do if M.mdKit[items:get(i):getFullType()] then has = true; break end end end) end
                if has then return { key = "medic:" .. uid, step = "restock", from = p, patient = patient } end
            end
            return nil -- nothing to treat with; the old 30 s check still tries if they find something
        end
        return { key = "medic:" .. uid, step = "treat", patient = patient }
    end,
    spot = function(j)
        if j.step == "restock" then return j.from end
        local x, y, z = H.pos(H.shellFor(j.patient))
        return x and { x = math.floor(x), y = math.floor(y), z = math.floor(z or 0) } or nil
    end,
    ms = function(j) return j.step == "restock" and 2000 or M.mdCfg.treatMs end,
    run = function(j, uid, shell, player)
        if j.step == "restock" then
            local sq = H.sqAt(j.from.x, j.from.y, j.from.z)
            local c = sq and H.containerOn(sq)
            local inv = H.invOf(shell)
            local n = 0
            if c and inv then
                local picks = {}
                pcall(function() local items = c:getItems(); for i = 0, items:size() - 1 do local it = items:get(i); if M.mdKit[it:getFullType()] and #picks < M.mdCfg.kit then picks[#picks + 1] = it end end end)
                for _, it in ipairs(picks) do if pcall(function() c:DoRemoveItem(it); inv:AddItem(it) end) then n = n + 1 end end
            end
            if n == 0 then return "done" end
            M.mdStats.restocked = M.mdStats.restocked + 1
            j.step = "treat"
            return "next"
        end
        local P = M.patch and M.patch() or nil
        if P == nil or not H.fn(P, "treatOther") then return "done" end
        local ok, done, kind = pcall(P.treatOther, uid, j.patient)
        if ok and done then
            M.mdStats.treated = M.mdStats.treated + 1
            M.cpStats.treated = M.cpStats.treated + 1
            if M.mdScore(j.patient) >= 4 then M.cpLog("medic", H.firstName(uid) .. " patched up " .. H.firstName(j.patient)) end
            H.log(H.firstName(uid) .. " (medic) treated " .. H.firstName(j.patient) .. " with " .. tostring(kind) .. " (triage)")
        end
        return "done"
    end,
})

-- menu: Camp > Medical
M.cpMenus = M.cpMenus or {}
table.insert(M.cpMenus, function(child, off, player, x, y, z, inRange, why)
    local mm, mo = child("Medical")
    if M.cpOpt("CPSickBay") == false then off(mo, "The sick bay is off in this world's sandbox settings.") end
    local md = M.mdData()
    if md.bay and md.bay.x == x and md.bay.y == y and md.bay.z == z then
        mm:addOption(ALifeTr("IGUI_ALCP_Menu_Not_the_sick_bay_anymore", "Not the sick bay anymore"), nil, function() M.cpAct("mdBayOff", nil, nil, nil, nil, nil, player) end)
    else
        local o = mm:addOption(md.bay and "Move the sick bay here" or "Sick bay here", nil, function() M.cpAct("mdBay", x, y, z, nil, nil, player) end)
        if not inRange then off(o, why or "Too far from your base.") end
    end
    local hurt = {}
    for _, u in ipairs(M.cpPeople(player)) do if M.mdScore(u) > 0 then hurt[#hurt + 1] = u end end
    table.sort(hurt, function(a, b) return M.mdScore(a) > M.mdScore(b) end)
    for i = 1, math.min(4, #hurt) do
        local s = state(hurt[i]) or {}
        local how = (s.bleeding or 0) > 0 and "bleeding" or (s.fracture and "broken bone" or (s.limp and "limping" or "hurt"))
        off(mm:addOption(H.firstName(hurt[i]) .. ": " .. how), "Medics see the worst first.")
    end
    if #M.cpWithRole("medic", player) == 0 then off(mm:addOption(ALifeTr("IGUI_ALCP_Menu_Nobody_s_the_medic", "Nobody's the medic")), "Camp > Roles > Medic. Stock bandages at a meds drop point (Haul & sort).") end
end)
-- pre-1.0 MP (P4): this menu's writes (M.cpAct: SP directly, MP on the server as the sender)
M.cpActs = M.cpActs or {}
M.cpActs.mdBayOff = function() M.mdData().bay = nil end
M.cpActs.mdBay = function(player, x, y, z)
    x, y, z = M.cpNum(x), M.cpNum(y), M.cpNum(z) or 0
    if x == nil or y == nil or (H.fn(M, "wzInRange") and not M.wzInRange(player, x, y)) then return false end
    M.mdData().bay = { x = x, y = y, z = z }
    H.halo("Sick bay set. The hurt rest here, and medics see the worst first.")
end
M.cpMarks = M.cpMarks or {}
table.insert(M.cpMarks, function() local b = M.mdData().bay; if b then return { { b, 0.3, 0.9, 0.4 } } end end)
