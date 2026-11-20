-- A-Life NPC Overhaul 0.7.0.2: one way for this mod to tell you something that isn't a decision.
-- With letters on (sandbox: Toasts) it becomes a letter at the right edge (shows, shrinks, stays until you clear it);
-- otherwise the old note over your head. Colours: 0-255. bad = true: red.
-- No game calls at load: safe in shared, loads before every other file (AA_ prefix).
-- pre-1.0 MP: on a server there is no screen: the letter goes to that player's machine (ALifeOut "out"; no player =
-- the player being handled, else everyone online), where this same function shows it. SP / MP client: unchanged.
function ALifeLetter(player, text, r, g, b, bad)
    if text == nil or text == "" then return false end
    text = tostring(text)
    if type(isServer) == "function" and isServer() then
        if type(ALifeOut) ~= "table" or type(ALifeOut.letter) ~= "function" then return false end
        if player == nil and type(ALifeSide) == "table" then player = ALifeSide.cur end
        return ALifeOut.letter(player, text, r, g, b, bad) > 0
    end
    if bad == true then r, g, b = 242, 107, 87 end
    local M = ALifeLLMTalk
    if type(M) == "table" and type(M.momToast) == "function" then
        local ok, shown = pcall(M.momToast, text, r or 242, g or 217, b or 166)
        if ok and shown then return true end
    end
    local ok = pcall(function()
        local p = player or (type(getSpecificPlayer) == "function" and getSpecificPlayer(0)) or nil
        if p then p:setHaloNote(text, r or 230, g or 200, b or 140, 400) end
    end)
    return ok
end
