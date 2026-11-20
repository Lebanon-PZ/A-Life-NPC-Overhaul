-- Right-click an A-Life NPC -> "Bonds" shows your Love / Fear / Need with them (hover for detail).
require "ISUI/ISWorldObjectContextMenu"

local TAG = "[ALifeBondsMenu]"
local faults = 0

local function clickedShell(worldobjects)
    local function owned(c)
        if c == nil or type(c.getModData) ~= "function" then return nil end
        local ok, data = pcall(function() return c:getModData() end)
        if ok and type(data) == "table" and type(data.ProjectALifeUID) == "string" then return c, data.ProjectALifeUID end
        return nil
    end
    for _, c in ipairs(type(worldobjects) == "table" and worldobjects or {}) do
        local s, uid = owned(c)
        if s then return s, uid end
    end
    for _, o in ipairs(type(worldobjects) == "table" and worldobjects or {}) do
        local sq
        pcall(function() sq = o:getSquare() end)
        local moving
        pcall(function() moving = sq and sq:getMovingObjects() end)
        if moving ~= nil then
            local n = 0
            pcall(function() n = moving:size() end)
            for i = 0, n - 1 do
                local c
                pcall(function() c = moving:get(i) end)
                local s, uid = owned(c)
                if s then return s, uid end
            end
        end
    end
    return nil
end

local function bar(points)
    local B = ALifeBonds
    local nextAt = B.nextOf(points)
    if nextAt == nil then return "max" end
    return math.floor(points) .. " / " .. nextAt
end

local WHY = {
    not_surrendered = "They have to be held up (hands up) by you first.",
    not_in_base = "Prisoners are only taken inside your base (a setting): hold them up, then order them to follow you.",
    not_here = "They are not here.",
    no_rope = "You need rope to tie them up.",
    not_tied = "Not tied.",
    already = "Already done.", no_leverage = "You need leverage: one of their people as your prisoner, or this person truly afraid of you.",
    not_due = "Not due yet.", no_deal = "No deal with their people.",
}

local function tipFor(option, text)
    local pool = ISInventoryPaneContextMenu
    if pool == nil or type(pool.addToolTip) ~= "function" then return end
    local tip = pool.addToolTip()
    if tip ~= nil then tip.description = text; option.toolTip = tip end
end

local function addPower(context, player, uid)
    local P, B = ALifeBondsPower, ALifeBonds
    if P == nil or B == nil then return end
    local reg = ProjectALife and ProjectALife.ActorRegistry
    local record = reg and reg.read(uid) or nil
    if record == nil then return end
    local key = B.keyOf(player)
    local cap = P.state().cap[uid]
    if cap ~= nil and cap.key == key then
        local days = math.floor((getGameTime():getWorldAgeHours() - (cap.since or 0)) / 24)
        if cap.tied then
            local u = context:addOption(ALifeTr("IGUI_ALCP_Menu_Untie_prisoner", "Untie prisoner (rope back)"), player, function(p) P.untie(p, uid) end)
            tipFor(u, "Only inside your base. Untied, they can work, and they can run.")
        else
            local t = context:addOption(ALifeTr("IGUI_ALCP_Menu_Tie_prisoner", "Tie prisoner up"), player, function(p) P.tie(p, uid) end)
            tipFor(t, "Uses rope. Tied, they cannot work and rarely get loose.")
        end
        if cap.cell ~= nil then
            context:addOption(ALifeTr("IGUI_ALCP_Menu_Unconfine", "Let out of cell"), player, function(p) P.unconfine(p, uid) end)
        else
            local k = context:addOption(ALifeTr("IGUI_ALCP_Menu_Confine", "Confine to this room"), player, function(p) P.confine(p, uid) end)
            tipFor(k, "Their cell. They stay in it; leaving your base is an escape attempt. Inside your base only.")
        end
        if cap.leading then
            local s = context:addOption(ALifeTr("IGUI_ALCP_Menu_Stop_leading", "Hold prisoner here"), player, function(p) P.stopLead(p, uid) end)
            tipFor(s, "They stop and stand with hands up.")
        else
            local l = context:addOption(ALifeTr("IGUI_ALCP_Menu_Lead_prisoner", "Lead prisoner (follow me)"), player, function(p) P.lead(p, uid) end)
            tipFor(l, "They walk after you. At your base they stop on their own.")
        end
        context:addOption("Release prisoner (held " .. days .. " days)", player, function(p) P.release(p, uid) end)
    elseif P.surrenderedTo(record, key) then
        local ok, why = P.canTake(player, record)
        local o = context:addOption(ALifeTr("IGUI_ALCP_Menu_Take_prisoner", "Take prisoner"), player, function(p) P.take(p, uid) end)
        if not ok then o.notAvailable = true; tipFor(o, WHY[why] or why) end
        tipFor(o, ok and "Ties them up with rope. Stay close, or bring them to your base. Their whole faction will fear you while you do." or (WHY[why] or why))
    end
    if record.factionId ~= nil then
        local deal = P.dealOf(key, record.factionId)
        if deal == nil then
            local ok, why = P.canDemand(player, record)
            if ok then
                local o = context:addOption(ALifeTr("IGUI_ALCP_Menu_Demand_tribute_from_their_people", "Demand tribute from their people"), player, function(p) P.demand(p, uid) end)
                tipFor(o, "Every 3 days any of them can be made to pay what they carry. Hurt their people and the deal breaks.")
            end
        else
            local due = P.tributeDueIn(key, record.factionId) or 0
            local o = context:addOption(ALifeTr("IGUI_ALCP_Menu_Collect_tribute", "Collect tribute"), player, function(p) P.collect(p, uid) end)
            if due > 0 then o.notAvailable = true; tipFor(o, "Due in " .. math.ceil(due) .. " hours.")
            else tipFor(o, "They hand over what they carry. If they've stopped fearing you, they'll refuse and the deal ends.") end
        end
    end
end

local function fill(playerNum, context, worldobjects, test)
    if test or ALifeBonds == nil then return end
    local ok = pcall(function()
        local shell, uid = clickedShell(worldobjects)
        if shell == nil then return end
        local player = getSpecificPlayer(playerNum)
        local B = ALifeBonds
        local key = B.keyOf(player)
        local r = B.row(key, uid, false)
        if ALifeImmersion ~= nil and ALifeImmersion.enabled then
            addPower(context, player, uid)          -- actions stay; numbers go. Ask them instead.
            return
        end
        local label
        if r == nil then
            label = "Bonds: none yet"
        else
            label = "Bonds: " .. B.nameOf("l", r.l) .. " / " .. B.nameOf("f", r.f) .. " / " .. B.nameOf("n", r.n)
            if r.partner then label = label .. " (partner)" end
        end
        local option = context:addOption(label, nil, nil)
        local pool = ISInventoryPaneContextMenu
        if pool ~= nil and type(pool.addToolTip) == "function" then
            local tip = pool.addToolTip()
            if tip ~= nil then
                if r == nil then
                    tip.description = "You haven't built anything with them yet. Time together, help, gifts and how you treat their people all count."
                else
                    local romance = r.partner and "Partner" or ((r.r or 0) >= 10 and "Interested" or "None")
                    tip.description = "Love: " .. B.nameOf("l", r.l) .. "  (" .. bar(r.l) .. ")"
                        .. " <LINE> Fear: " .. B.nameOf("f", r.f) .. "  (" .. bar(r.f) .. ")"
                        .. " <LINE> Need: " .. B.nameOf("n", r.n) .. "  (" .. bar(r.n) .. ")"
                        .. " <LINE> Romance: " .. romance
                        .. " <LINE> <LINE> Each stage takes twice the last."
                end
                option.toolTip = tip
            end
        end
        addPower(context, player, uid)
    end)
    if not ok then
        faults = faults + 1
        if faults == 1 then print(TAG .. " menu failed once (further failures silent)") end
    end
end

if Events ~= nil and Events.OnFillWorldObjectContextMenu ~= nil then
    ALifeRadial.addFiller("bonds", "npc", fill)   -- 0.5.11: radial registry
end
print(TAG .. " loaded")
