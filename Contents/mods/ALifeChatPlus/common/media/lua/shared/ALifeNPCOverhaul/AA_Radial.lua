-- A-Life NPC Overhaul 0.5.11: menu registry for the radial menu.
-- Every right-click builder of this mod registers here instead of straight on Events.OnFillWorldObjectContextMenu.
-- The radial (client/ALifeNPCOverhaul/ALifeRadialMenu.lua) runs the same builders into an off-screen context menu and
-- shows what they made as radial slices, so the radial and the old menu never drift apart.
-- On right-click a builder only runs when the player wants the old long menu (setting radialMenu = false);
-- otherwise right-click gets one "A-Life" entry that opens the radial.
-- No game calls here: safe in shared, loads before every client file (AA_ prefix).

ALifeRadial = ALifeRadial or {}
local R = ALifeRadial
R.fillers = R.fillers or {}       -- { id, group, fn } in registration order
R.capturing = false               -- true while the radial runs the builders

-- the old long right-click menu? (default: no, the radial replaces it)
function R.legacy()
    local M = ALifeLLMTalk
    return type(M) == "table" and type(M.settings) == "table" and M.settings.radialMenu == false
end

-- group: "npc" (the person you clicked / next to), "camp" (Camp, Work zones), "windows" (Places, Party, ...)
function R.addFiller(id, group, f)
    if type(f) ~= "function" then return end
    for _, e in ipairs(R.fillers) do
        if e.id == id then e.fn, e.group = f, group; return end     -- a reload replaces, never doubles
    end
    R.fillers[#R.fillers + 1] = { id = id, group = group or "windows", fn = f }
    if type(Events) == "table" and Events.OnFillWorldObjectContextMenu then
        Events.OnFillWorldObjectContextMenu.Add(function(playerNum, context, worldobjects, test)
            if R.capturing or not R.legacy() then return end
            for _, e in ipairs(R.fillers) do
                if e.id == id then
                    local ok, err = pcall(e.fn, playerNum, context, worldobjects, test)
                    if not ok and not e.faulted then e.faulted = true; print("[ALifeRadial] menu part '" .. id .. "' failed (logged once): " .. tostring(err)) end
                    return
                end
            end
        end)
    end
end
