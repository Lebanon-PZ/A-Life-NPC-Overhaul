-- A-Life NPC Overhaul 0.5.11: THE RADIAL MENU.
-- The right-click menu had grown to a dozen "A-Life Talk: ..." lines. Now right-click shows one entry, "A-Life",
-- and that opens a radial with everything sorted: the person next to you, Camp, Work zones, Windows.
--
-- How: every right-click builder of this mod registers in ALifeRadial (shared/ALifeNPCOverhaul/AA_Radial.lua). To open
-- the radial we run those same builders into the player's context menu WITHOUT showing it (vanilla
-- ISContextMenu.get, the call a right-click makes), read the options tree they made (name, icon, onSelect + params,
-- notAvailable + tooltip, submenus) and hide it again in the same frame. Nothing is built twice and nothing can
-- drift: a new menu entry anywhere in the mod shows up in the radial by itself.
--
-- The radial is vanilla's own player radial (getPlayerRadialMenu, the vehicle menu's widget), so:
--   * vehicle menu (V / D-pad up): gets an "A-Life" slice, in or next to a vehicle (wraps ISVehicleMenu, keeps theirs)
--   * D-pad up with nothing else to show (no vehicle, no animal): opens the A-Life radial (only without SRM)
--   * Smart Radial Menu installed: registers through its public SRMAPI (Mods > A-Life), and stays off its D-pad hook
--   * hotkey: Options > Mods > A-Life NPC Overhaul > "A-Life radial menu" (unbound by default)
-- Settings: radialMenu (off = the old long right-click menu back), radialPad (D-pad up fallback).
-- No per-frame work: everything runs on a key press, a click or a menu open.

require "ISUI/ISRadialMenu"
require "ISUI/ISContextMenu"

local TAG = "[ALifeRadial]"
local VERSION = "0.7.0.1"
local R = ALifeRadial
local M = ALifeLLMTalk
local PAGE = 10                    -- content slices a page (plus Back / More)

local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end

-- settings (same pattern as the other modules: default + saved in the settings file)
local function setting(key, default)
    if type(M) ~= "table" or type(M.settings) ~= "table" then return end
    if M.settings[key] == nil then M.settings[key] = default end
    if type(M.fileKeys) == "table" then
        local have = false
        for _, x in ipairs(M.fileKeys) do if x == key then have = true end end
        if not have then M.fileKeys[#M.fileKeys + 1] = key end
    end
end
setting("radialMenu", true)   -- right-click: one "A-Life" entry that opens the radial (false = the old long menu)
setting("radialPad", true)    -- D-pad up with nothing else to show opens the A-Life radial (not with SRM)

----------------------------------------------------------------------------------------------------------------
-- textures (only files that exist: ours in media/ui/ALifeTalk, vanilla's context-menu arrows)
----------------------------------------------------------------------------------------------------------------
local TEX = {}
local function tex(name)
    if TEX[name] ~= nil then return TEX[name] or nil end
    local path = name
    if not string.find(name, "/", 1, true) then path = "media/ui/ALifeTalk/" .. name .. ".png" end
    local ok, t = pcall(getTexture, path)
    TEX[name] = (ok and t) or false
    return TEX[name] or nil
end
local function backTex() return tex("media/ui/ArrowUp.png") end
local function moreTex() return tex("media/ui/ArrowDown.png") end

----------------------------------------------------------------------------------------------------------------
-- capture: run our builders into the (hidden) player context menu and copy what they made
----------------------------------------------------------------------------------------------------------------
local function tipText(o)
    local t = o.toolTip
    local d = type(t) == "table" and t.description or nil
    if type(d) ~= "string" or d == "" then return nil end
    d = string.gsub(d, "<LINE>", " ")
    d = string.gsub(d, "<[^>]*>", "")
    d = string.gsub(d, "%s+", " ")
    return d
end
local function clean(label)
    local s = tostring(label or "?")
    s = string.gsub(s, "^A%-Life Talk: ", "")
    s = string.gsub(s, "^A%-Life: ", "") -- pre-1.0: the long menu says "A-Life: ..." now
    return s
end
local function readMenu(menu, depth)
    local out = {}
    if type(menu) ~= "table" or type(menu.options) ~= "table" then return out end
    local n = (tonumber(menu.numOptions) or 1) - 1
    for i = 1, n do
        local o = menu.options[i]
        if type(o) == "table" and o.name ~= nil then
            local node = { label = clean(o.name), icon = o.iconTexture, f = o.onSelect, target = o.target,
                p = { o.param1, o.param2, o.param3, o.param4, o.param5, o.param6, o.param7, o.param8, o.param9, o.param10 },
                tip = tipText(o) }
            if o.notAvailable or o.isDisabled then node.off = node.tip or "Not right now." end
            if o.subOption ~= nil and depth < 6 then
                local okS, sm = pcall(function() return menu:getSubMenu(o.subOption) end)
                if okS and sm then node.sub = readMenu(sm, depth + 1) end
            end
            out[#out + 1] = node
        end
    end
    return out
end
local function recycleTips()
    for _, owner in ipairs({ ISWorldObjectContextMenu, ISInventoryPaneContextMenu }) do
        if type(owner) == "table" and type(owner.tooltipsUsed) == "table" and type(owner.tooltipPool) == "table" then
            for _, t in ipairs(owner.tooltipsUsed) do owner.tooltipPool[#owner.tooltipPool + 1] = t end
            if type(table.wipe) == "function" then table.wipe(owner.tooltipsUsed)
            else for i = #owner.tooltipsUsed, 1, -1 do owner.tooltipsUsed[i] = nil end end
        end
    end
end
R.fillFaults = R.fillFaults or {}
function R.capture(playerNum, worldobjects)
    local groups = { npc = {}, camp = {}, windows = {} }
    local ctx = ISContextMenu.get(playerNum, 0, 0)
    R.capturing = true
    for _, e in ipairs(R.fillers) do
        local before = (tonumber(ctx.numOptions) or 1)
        local ok, err = pcall(e.fn, playerNum, ctx, worldobjects, false)
        if not ok and not R.fillFaults[e.id] then R.fillFaults[e.id] = true; log("menu part '" .. e.id .. "' failed (logged once): " .. tostring(err)) end
        e.lastFrom, e.lastTo = before, (tonumber(ctx.numOptions) or 1) - 1
    end
    R.capturing = false
    local all = readMenu(ctx, 0)
    groups.byId = {}
    for _, e in ipairs(R.fillers) do
        local g = groups[e.group] or groups.windows
        local mine = {}
        for i = e.lastFrom or 1, e.lastTo or 0 do if all[i] then g[#g + 1] = all[i]; mine[#mine + 1] = all[i] end end
        groups.byId[e.id] = mine
    end
    pcall(function() ctx:hideAndChildren() end)
    pcall(function() ctx:setVisible(false) end)
    recycleTips()
    return groups
end

-- the root ring: the person (Talk straight on the ring, the rest in their slice), Camp, Work zones, Windows
function R.build(groups)
    local root = {}
    local rest, talk, name = {}, nil, nil
    for _, node in ipairs(groups.npc) do
        local who = string.match(node.label, "^Talk to (.-) %(")
        if talk == nil and who then talk, name = node, who; node.icon = node.icon or tex("talk")
        else rest[#rest + 1] = node end
    end
    if talk then root[#root + 1] = talk end
    if #rest > 0 then root[#root + 1] = { label = name or "This person", icon = tex("heart"), sub = rest } end
    for _, node in ipairs(groups.camp) do node.icon = node.icon or tex("gear"); root[#root + 1] = node end
    if #groups.windows > 0 then root[#root + 1] = { label = "Windows", icon = tex("side_rel_on"), sub = groups.windows } end
    return root
end

----------------------------------------------------------------------------------------------------------------
-- 0.7.0.1: THE QUICK WHEEL. Eight slices or fewer, one level deep at most. The long lists live in the A-Life window
-- and on right-click > A-Life. The old wheel (everything) is one switch away: Settings > "Radial: quick wheel".
----------------------------------------------------------------------------------------------------------------
function R.quickOn() return not (type(M) == "table" and type(M.settings) == "table" and M.settings.radialQuick == false) end
local function say(text) if fn(M, "momToast") then pcall(M.momToast, text) end end
local function order(id, uid, label)
    return { label = label, icon = tex("follow"), f = function()
        local ok = fn(M, "qoRun") and M.qoRun(id, uid)
        say(ok and label or "Nobody took that order.")
    end, p = {} }
end
local function uidOf(shell)
    local uid = nil
    pcall(function() uid = shell:getModData().ProjectALifeUID end)
    return type(uid) == "string" and uid or nil
end
local function canOrder(id, uid)
    local o = type(M.qoById) == "table" and M.qoById[id] or nil
    if o == nil then return false end
    local ok, res = pcall(function() return o.ok == nil or o.ok(uid) end)
    return ok and res == true
end
-- the person ring
function R.personRing(groups, uid, playerObj)
    local nodes, rest, talk, name = {}, {}, nil, nil
    for _, node in ipairs(groups.npc or {}) do
        local who = string.match(node.label, "^Talk to (.-) %(")
        if talk == nil and who then talk, name = node, who; node.icon = node.icon or tex("talk")
        else rest[#rest + 1] = node end
    end
    if talk then nodes[#nodes + 1] = talk end
    if uid then
        for _, id in ipairs({ "follow", "wait", "guard" }) do
            if canOrder(id, uid) then nodes[#nodes + 1] = order(id, uid, M.qoById[id].label) end
        end
        -- Orders: one flat list (home, jobs, named places, stand down)
        local sub = {}
        if canOrder("home", uid) then sub[#sub + 1] = order("home", uid, M.qoById.home.label) end
        if fn(M, "cpSetRole") and type(M.cpRoles) == "table" and fn(M, "cpIsHome") and M.cpIsHome(uid, playerObj) then
            for _, r in ipairs(M.cpRoles) do
                sub[#sub + 1] = { label = "Job: " .. r.label, icon = tex("gear"), f = function()
                    local n = fn(M, "bulkOrder") and M.bulkOrder({ uid }, "role", r.id) or 0
                    if n == 0 then say("They won't take that job.") end
                end, p = {} }
            end
        end
        local places = fn(M, "qolStore") and M.qolStore().places or {}
        if fn(M, "plOrder") and (canOrder("follow", uid) or (fn(M, "cpIsHome") and M.cpIsHome(uid, playerObj))) then
            for _, pl in ipairs(places) do
                sub[#sub + 1] = { label = "Meet me at " .. pl.name, icon = tex("follow"), f = function() M.plOrder(uid, pl.id, "meet") end, p = {} }
                sub[#sub + 1] = { label = "Hold " .. pl.name, icon = tex("follow"), f = function() M.plOrder(uid, pl.id, "hold") end, p = {} }
            end
        end
        if canOrder("recall", uid) then sub[#sub + 1] = order("recall", uid, "Stand down") end
        if #sub > 0 then nodes[#nodes + 1] = { label = "Orders", icon = tex("gear"), sub = sub } end
        if fn(M, "winPeopleAt") then
            nodes[#nodes + 1] = { label = "Their page", icon = tex("heart"), f = function() M.winPeopleAt(uid) end, p = {} }
        end
    end
    if #rest > 0 then nodes[#nodes + 1] = { label = name and ("More with " .. name) or "More with them", icon = tex("heart"), sub = rest } end -- pre-1.0: was "Everything else" (twice)
    return nodes
end
-- the ring when you point at nobody: your quick orders (the same buttons as the quick-order bar), plus a few doors
function R.placeRing(groups, playerObj)
    local nodes = {}
    for _, q in ipairs(type(M.qoOrders) == "table" and M.qoOrders or {}) do
        if q.who ~= "person" and (not fn(M, "uiPref") or M.uiPref("quick.show." .. q.id, true)) and canOrder(q.id) then
            nodes[#nodes + 1] = order(q.id, nil, q.label)
        end
    end
    if fn(M, "plAsk") and M.settings.namedPlaces ~= false then
        nodes[#nodes + 1] = { label = "Name this spot", icon = tex("follow"), f = function()
            local x, y, z = math.floor(playerObj:getX()), math.floor(playerObj:getY()), math.floor(playerObj:getZ())
            M.plAsk(x, y, z)
        end, p = {} }
    end
    local radio = groups.byId and groups.byId.radio or {}
    if #radio > 0 then
        local sub = radio
        if #radio == 1 and radio[1].sub then sub = radio[1].sub end
        nodes[#nodes + 1] = { label = "Radio", icon = tex("side_rel_on"), sub = sub }
    end
    if fn(M, "hubOpen") then nodes[#nodes + 1] = { label = "A-Life window", icon = tex("side_rel_on"), f = function() M.hubOpen() end, p = {} } end
    local all = R.build(groups)
    if #all > 0 then nodes[#nodes + 1] = { label = "All of A-Life", icon = tex("gear"), sub = all } end
    return nodes
end

----------------------------------------------------------------------------------------------------------------
-- where: the square under the mouse (keyboard) or around you (controller), and who's there
----------------------------------------------------------------------------------------------------------------
local function isPad(playerNum) return type(JoypadState) == "table" and JoypadState.players and JoypadState.players[playerNum + 1] ~= nil end
local function objectsOf(sq)
    local out = {}
    if sq == nil then return out end
    pcall(function() local objs = sq:getObjects(); for i = 0, objs:size() - 1 do out[#out + 1] = objs:get(i) end end)
    return out
end
local function shellOn(sq)
    local found = nil
    pcall(function()
        local mv = sq:getMovingObjects()
        for i = 0, mv:size() - 1 do
            local c = mv:get(i)
            if c ~= nil and c:hasModData() and type(c:getModData().ProjectALifeUID) == "string" then found = c; return end
        end
    end)
    return found
end
-- near = true: ignore the mouse (opened from another menu, where the mouse sits on that menu over your own feet)
function R.whereFor(playerObj, near)
    local playerNum = playerObj:getPlayerNum()
    local cell = getCell()
    local z = math.floor(playerObj:getZ())
    local sq = nil
    if not near and not isPad(playerNum) and playerNum == 0 then
        pcall(function()
            local wx, wy = ISCoordConversion.ToWorld(getMouseXScaled(), getMouseYScaled(), z)
            sq = cell:getGridSquare(math.floor(wx), math.floor(wy), z)
        end)
    else
        -- controller: the nearest A-Life person within 3 tiles, else where you stand
        local px, py = math.floor(playerObj:getX()), math.floor(playerObj:getY())
        local best, bestD = nil, nil
        for dx = -3, 3 do
            for dy = -3, 3 do
                local s = cell:getGridSquare(px + dx, py + dy, z)
                if s and shellOn(s) then
                    local d = dx * dx + dy * dy
                    if bestD == nil or d < bestD then best, bestD = s, d end
                end
            end
        end
        sq = best
    end
    if sq == nil then sq = playerObj:getSquare() end
    return objectsOf(sq), shellOn(sq)
end

----------------------------------------------------------------------------------------------------------------
-- showing it (vanilla's player radial; a submenu replaces the ring, Back returns)
----------------------------------------------------------------------------------------------------------------
R.view = R.view or {}
local function halo(playerObj, text)
    if playerObj and text then pcall(function() playerObj:setHaloNote(tostring(text), 220, 200, 140, 300) end) end
end
function R.show(playerNum, nodes, parent, page, releaseBtn)
    local playerObj = getSpecificPlayer(playerNum)
    if playerObj == nil then return end
    local menu = getPlayerRadialMenu(playerNum)
    if menu == nil then return end
    page = page or 1
    R.view[playerNum] = { nodes = nodes, parent = parent, page = page }
    menu:clear()
    if parent then menu:addSlice("Back", backTex(), R.back, playerNum) end
    local first = (page - 1) * PAGE + 1
    local last = math.min(#nodes, first + PAGE - 1)
    for i = first, last do
        local node = nodes[i]
        local icon = node.icon or (parent and parent.icon) or tex("talk")
        if node.sub then
            menu:addSlice(node.label .. "  >", icon, R.enter, playerNum, node)
        elseif node.off then
            menu:addSlice(node.label .. "  (not now)", icon, R.why, playerNum, node)
        else
            menu:addSlice(node.label, icon, R.run, playerNum, node)
        end
    end
    if last < #nodes then menu:addSlice("More (" .. (#nodes - last) .. ")", moreTex(), R.page, playerNum, page + 1)
    elseif page > 1 then menu:addSlice("Back to the start", moreTex(), R.page, playerNum, 1) end
    if menu:isEmpty() then halo(playerObj, "Nothing to do here."); return end
    menu.alifeRadialOpen = true
    menu:setX(getPlayerScreenLeft(playerNum) + getPlayerScreenWidth(playerNum) / 2 - menu:getWidth() / 2)
    menu:setY(getPlayerScreenTop(playerNum) + getPlayerScreenHeight(playerNum) / 2 - menu:getHeight() / 2)
    menu:addToUIManager()
    if not parent and page == 1 then pcall(function() getSoundManager():playUISound("UIVehicleMenuOpen") end) end
    menu.sounds.undisplay = "UIVehicleMenuClose"
    if isPad(playerNum) then
        menu:setHideWhenButtonReleased(releaseBtn or Joypad.AButton)   -- tilt the stick at a slice, press A (or let go of D-pad up)
        setJoypadFocus(playerNum, menu)
        playerObj:setJoypadIgnoreAimUntilCentered(true)
    end
end
function R.enter(playerNum, node)
    local v = R.view[playerNum]
    node.back = v
    R.show(playerNum, node.sub, node, 1)
end
function R.back(playerNum)
    local v = R.view[playerNum]
    local parent = v and v.parent or nil
    local up = parent and parent.back or nil
    if up then R.show(playerNum, up.nodes, up.parent, up.page) end
end
function R.page(playerNum, page)
    local v = R.view[playerNum]
    if v then R.show(playerNum, v.nodes, v.parent, page) end
end
function R.why(playerNum, node)
    halo(getSpecificPlayer(playerNum), node.off)
end
R.runFaults = 0
function R.run(playerNum, node)
    if type(node.f) ~= "function" then
        -- an information line (like Bonds): its tooltip is the content
        halo(getSpecificPlayer(playerNum), node.tip or node.label)
        return
    end
    local p = node.p
    local ok, err = pcall(node.f, node.target, p[1], p[2], p[3], p[4], p[5], p[6], p[7], p[8], p[9], p[10])
    if not ok then
        R.runFaults = R.runFaults + 1
        if R.runFaults <= 3 then log("'" .. tostring(node.label) .. "' failed: " .. tostring(err)) end
    end
end

-- open: worldobjects = what was right-clicked (or nil: under the mouse / around you)
function R.open(playerObj, worldobjects, releaseBtn, near)
    if playerObj == nil or playerObj:isDead() then return end
    local speed = UIManager.getSpeedControls()
    if speed and speed:getCurrentGameSpeed() == 0 then return end
    local playerNum = playerObj:getPlayerNum()
    local shell = nil
    if worldobjects == nil then
        local okW, wo, sh = pcall(R.whereFor, playerObj, near)
        if okW and type(wo) == "table" then worldobjects, shell = wo, sh
        else worldobjects = {}; if not R.whereFault then R.whereFault = true; log("could not find the square under the mouse (logged once): " .. tostring(wo)) end end
    else
        for _, o in ipairs(worldobjects) do
            if shell == nil then pcall(function() local sq = o:getSquare(); if sq then shell = shellOn(sq) end end) end
        end
    end
    local okC, groups = pcall(R.capture, playerNum, worldobjects)
    if not okC then R.capturing = false; log("could not build the menu: " .. tostring(groups)); return end
    local root
    if R.quickOn() then
        local okQ, res = pcall(function()
            local uid = shell and uidOf(shell) or nil
            if uid or #(groups.npc or {}) > 0 then return R.personRing(groups, uid, playerObj) end
            return R.placeRing(groups, playerObj)
        end)
        if okQ and type(res) == "table" and #res > 0 then root = res
        elseif not okQ and not R.quickFault then R.quickFault = true; log("quick wheel off for this session: " .. tostring(res)) end
    end
    root = root or R.build(groups)
    R.show(playerNum, root, nil, 1, releaseBtn)
end
function R.toggle(playerObj)
    local menu = getPlayerRadialMenu(playerObj:getPlayerNum())
    if menu and menu:isReallyVisible() then
        local ours = menu.alifeRadialOpen == true
        if menu.joyfocus then setJoypadFocus(playerObj:getPlayerNum(), nil) end
        menu:undisplay()
        if ours then return end
    end
    R.open(playerObj)
end

----------------------------------------------------------------------------------------------------------------
-- right-click: one entry instead of the long list
----------------------------------------------------------------------------------------------------------------
if type(Events) == "table" and Events.OnFillWorldObjectContextMenu then
    Events.OnFillWorldObjectContextMenu.Add(function(playerNum, context, worldobjects, test)
        if test == true or R.capturing or R.legacy() or type(context) ~= "table" then return end
        if type(M) == "table" and type(M.settings) == "table" and M.settings.enabled == false then return end
        local saved = {}
        for i, o in ipairs(worldobjects or {}) do saved[i] = o end
        if not R.quickOn() then
            local opt = context:addOption(ALifeTr("IGUI_ALCP_Menu_A_Life", "A-Life"), playerNum, function(pn)
                local p = getSpecificPlayer(pn)
                if p then R.open(p, saved) end
            end)
            if opt then opt.iconTexture = tex("talk") end
            return
        end
        -- 0.7.0.1: the quick wheel is for quick things; right-click > A-Life has the whole list, one menu deep per level
        local opt = context:addOption(ALifeTr("IGUI_ALCP_Menu_A_Life", "A-Life"), nil, nil)
        if opt == nil then return end
        opt.iconTexture = tex("talk")
        local sub = ISContextMenu:getNew(context)
        context:addSubMenu(opt, sub)
        local w = sub:addOption(ALifeTr("IGUI_ALCP_Menu_Quick_wheel", "Quick wheel"), playerNum, function(pn)
            local p = getSpecificPlayer(pn)
            if p then R.open(p, saved) end
        end)
        if w then w.iconTexture = tex("talk") end
        R.capturing = true
        for _, e in ipairs(R.fillers) do
            local ok, err = pcall(e.fn, playerNum, sub, saved, false)
            if not ok and not R.fillFaults[e.id] then R.fillFaults[e.id] = true; log("menu part '" .. e.id .. "' failed (logged once): " .. tostring(err)) end
        end
        R.capturing = false
    end)
end

----------------------------------------------------------------------------------------------------------------
-- hooks: vehicle menu, D-pad, Smart Radial Menu, hotkey
----------------------------------------------------------------------------------------------------------------
R.hooks = R.hooks or {}
local function fromOther(playerObj) R.open(playerObj, nil, nil, true) end -- 0.6.1: the person next to you
local function addOurSlice(playerObj)
    if playerObj == nil then return end
    local menu = getPlayerRadialMenu(playerObj:getPlayerNum())
    if menu == nil or not menu:isReallyVisible() then return end
    -- 0.7.11.1: another mod can own the wheel for a moment (Viewpoint harvests the vehicle radial into its own
    -- interaction menu, and slices isn't a Lua table then): leave that menu alone instead of erroring the hook off
    local slices = menu.slices
    if slices ~= nil and type(slices) ~= "table" then return end
    menu.alifeRadialOpen = false
    for _, s in ipairs(slices or {}) do if type(s) == "table" and type(s.command) == "table" and s.command[1] == fromOther then return end end
    menu:addSlice("A-Life", tex("talk"), fromOther, playerObj)
end
function R.hookVehicle()
    if type(ISVehicleMenu) ~= "table" then return false end
    if ISVehicleMenu._alifeRadial then return true end
    for _, name in ipairs({ "showRadialMenu", "showRadialMenuOutside" }) do
        local orig = ISVehicleMenu[name]
        if type(orig) == "function" then
            ISVehicleMenu[name] = function(playerObj, ...)
                local r1, r2 = orig(playerObj, ...)
                if not R.vehFault then
                    local ok, err = pcall(addOurSlice, playerObj)
                    if not ok then R.vehFault = true; log("vehicle menu slice off for this session: " .. tostring(err)) end
                end
                return r1, r2
            end
        end
    end
    ISVehicleMenu._alifeRadial = true
    return true
end
function R.hookPad()
    if type(ISDPadWheels) ~= "table" or type(ISDPadWheels.onDisplayUp) ~= "function" then return false end
    if ISDPadWheels._alifeRadial then return true end
    local orig = ISDPadWheels.onDisplayUp
    ISDPadWheels.onDisplayUp = function(joypadData, ...)
        local r1 = orig(joypadData, ...)
        if not R.padFault and type(M) == "table" and M.settings.radialPad ~= false then
            local ok, err = pcall(function()
                local pn = joypadData and joypadData.player
                local p = pn and getSpecificPlayer(pn)
                local menu = pn and getPlayerRadialMenu(pn)
                if p and menu and menu:isEmpty() and not menu:isReallyVisible() then R.open(p, nil, Joypad.DPadUp) end
            end)
            if not ok then R.padFault = true; log("D-pad hook off for this session: " .. tostring(err)) end
        end
        return r1
    end
    ISDPadWheels._alifeRadial = true
    return true
end
function R.hookSRM()
    if type(SRMAPI) ~= "table" or type(SRMAPI.AddCustomModSubmenu) ~= "function" then return false end
    local ok, res = pcall(SRMAPI.AddCustomModSubmenu, "ALifeChatPlus", "A-Life", tex("talk"), {
        { label = "Here / next to me", texture = tex("talk"), callback = function(p) R.open(p or ALifeSide.you(), nil, nil, true) end },
        { label = "Relationships", texture = tex("heart"), callback = function() if fn(M, "openRelationList") then M.openRelationList() end end },
        { label = "Party", texture = tex("side_party_on"), callback = function() if fn(M, "openParty") then M.openParty() end end },
        { label = "Places", texture = tex("follow"), callback = function() if fn(M, "openPlaces") then M.openPlaces() end end },
        { label = "Factions", texture = tex("side_rel_on"), callback = function(p) if fn(ALifeFactionsMenu, "show") then ALifeFactionsMenu.show(p or ALifeSide.you()) end end },
    })
    return ok and res == true
end

-- hotkey (Options > Mods)
R.keyOpt = nil
if type(PZAPI) == "table" and type(PZAPI.ModOptions) == "table" and fn(PZAPI.ModOptions, "create") then
    pcall(function()
        local o = PZAPI.ModOptions:create("ALifeChatPlus", "A-Life NPC Overhaul")
        R.keyOpt = o:addKeyBind("radialKey", "A-Life quick wheel", 0, "Opens the A-Life quick wheel for whoever / wherever your mouse is pointing (same as right-click > A-Life).")
        R.hubKeyOpt = o:addKeyBind("hubKey", "A-Life window", 0, "Opens / closes the A-Life window, where every tab is (people, camp, settings, help and the rest).") -- 0.6.10
        R.talkKeyOpt = o:addKeyBind("talkKey", "Talk to the nearest person", 0, "Opens the talk window with the closest A-Life person (a few tiles). Press again to close it.") -- 0.8.12
        R.repeatKeyOpt = o:addKeyBind("repeatOrderKey", "Repeat last order", 0, "Gives your last order again to the same people. Spots ('hold there') are worked out again from where you are.") -- 0.8.12
        R.hoverKeyOpt = o:addKeyBind("hoverKey", "Hover: read people", 0, "With 'hover line only while the key is held' on (A-Life Settings): hold this and point at someone to see how they are toward you.") -- 0.8.12
    end)
end
local function typing()
    local ok, busy = pcall(function() return type(ISChat) == "table" and ISChat.instance ~= nil and ISChat.instance.focused == true end)
    return ok and busy
end
if type(Events) == "table" and Events.OnKeyStartPressed then
    Events.OnKeyStartPressed.Add(function(key)
        local opt = R.keyOpt
        if opt == nil then return end
        local k = opt:getValue()
        if k == nil or k == 0 or key ~= k or typing() then return end
        local p = ALifeSide.you()
        if p == nil or p:isDead() then return end
        local ok, err = pcall(R.toggle, p)
        if not ok then log("hotkey failed: " .. tostring(err)) end
    end)
end

if type(Events) == "table" and Events.OnGameStart then
    Events.OnGameStart.Add(function()
        R.hooks.vehicle = R.hookVehicle()
        R.hooks.srm = R.hookSRM()
        R.hooks.pad = (type(SRMAPI) ~= "table") and R.hookPad() or false   -- SRM owns D-pad up when it's installed
        log("loaded v" .. VERSION .. " (" .. #R.fillers .. " menu parts; right-click " .. (R.legacy() and "old menu" or "one entry")
            .. "; vehicle menu " .. (R.hooks.vehicle and "yes" or "no") .. "; Smart Radial Menu " .. (R.hooks.srm and "yes" or "not installed")
            .. "; D-pad " .. (R.hooks.pad and "yes" or "no") .. ")")
    end)
end
