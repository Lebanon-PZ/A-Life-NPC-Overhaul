-- A-Life NPC Overhaul 0.6.12: translations. ALifeTr(key, english, ...) uses the translation from the language's
-- IG_UI.json (Translate/<LANG>/IG_UI.json, keys IGUI_ALCP_*) when there is one, else the English given here, so a
-- missing line never shows a raw key. {1}, {2} ... (in the files) and %1, %2 ... (in the code) are filled from the
-- extra arguments.
function ALifeTr(key, english, ...)
    local s = nil
    if type(getTextOrNull) == "function" then
        local ok, t = pcall(getTextOrNull, key)
        if ok and type(t) == "string" and t ~= "" and t ~= key then s = t end
    end
    s = s or tostring(english or key)
    local n = select("#", ...)
    if n > 0 then
        local args = { ... }
        local fill = function(d) local v = args[tonumber(d)]; return v ~= nil and tostring(v) or "" end
        s = string.gsub(s, "{(%d)}", fill)  -- translation files use {1}: the game's text formatter chokes on a bare %
        s = string.gsub(s, "%%(%d)", fill)  -- the English built into the code uses %1
    end
    return s
end
