-- A-Life NPC Overhaul: keep chat working when vanilla's chat box fails.
-- Some single-player games get "attempted index: hasCapability of non-table: null" from vanilla
-- ISChat.onCommandEntered (the player has no role). The typed text still reaches the NPCs (A-Life handles it
-- first), but vanilla then fails before closing the box or showing anything above your head.
-- If that happens, finish the job ourselves: clear and close the box and show what you said over your head.

local TAG = "[ALifeChatFix]"
ALifeChatFix = ALifeChatFix or {}
local X = ALifeChatFix
X.warned = false

local function roleMissing()
    local ok, role = pcall(function() return getPlayer():getRole() end)
    return ok and role == nil
end

function X.install()
    if X.__installed then return true end
    if type(ISChat) ~= "table" or type(ISChat.onCommandEntered) ~= "function" then return false end
    X.__installed = true
    local orig = ISChat.onCommandEntered
    ISChat.onCommandEntered = function(self, ...)
        local inst = ISChat.instance
        local text = ""
        pcall(function() text = inst.textEntry:getText() or "" end)
        local ok, err = pcall(orig, self, ...)
        if ok then return err end
        if not roleMissing() then error(err, 0) end        -- a different failure: leave it alone
        if not X.warned then
            X.warned = true
            print(TAG .. " vanilla chat failed (player has no role); finishing the message ourselves")
        end
        pcall(function() inst.textEntry:setText("") end)
        pcall(function() inst:unfocus() end)
        text = string.gsub(text, "^%s+", "")
        -- 0.7.0.1: a chat command typed in front ("/say hi", "/s hi", "/shout run") is not part of what they said
        local cmd, rest = string.match(text, "^/(%a+)%s+(.*)$")
        local shoutCmd = false
        if cmd then
            cmd = string.lower(cmd)
            if cmd == "say" or cmd == "s" then text = rest
            elseif cmd == "shout" or cmd == "yell" or cmd == "y" then text, shoutCmd = rest, true end
        end
        if text == "" then return end
        -- vanilla died before passing the line on, so hand it to the NPCs ourselves
        local Talk = ProjectALife and ProjectALife.Talk
        local loud = shoutCmd or string.find(text, "^!") ~= nil or string.find(text, "!$") ~= nil
        local recent = X.lastText == text and (getTimestampMs() - (X.lastAt or 0)) < 1500
        if not recent and Talk and type(Talk.onPlayerText) == "function" then
            pcall(Talk.onPlayerText, getPlayer(), text, loud)
        end
        pcall(function() getPlayer():Say(text) end)
    end
    -- remember what A-Life last heard, so a line it already got isn't sent twice
    local T = ProjectALife and ProjectALife.Talk
    if T and type(T.onPlayerText) == "function" and not X.__stamped then
        X.__stamped = true
        local o = T.onPlayerText
        T.onPlayerText = function(player, text, ...)
            X.lastText, X.lastAt = text, getTimestampMs()
            return o(player, text, ...)
        end
    end
    X.repoint()
    print(TAG .. " ready")
    return true
end

-- the chat box keeps the function it was built with, so point it at the current (wrapped) one
function X.repoint()
    pcall(function()
        local inst = ISChat.instance
        if inst and inst.textEntry then inst.textEntry.onCommandEntered = ISChat.onCommandEntered end
    end)
end

if type(ISChat) == "table" and type(ISChat.createChildren) == "function" and not X.__ccWrapped then
    X.__ccWrapped = true
    local cc = ISChat.createChildren
    ISChat.createChildren = function(self, ...)
        local r = cc(self, ...)
        pcall(function() if X.__installed then self.textEntry.onCommandEntered = ISChat.onCommandEntered end end)
        return r
    end
end

if Events ~= nil and Events.OnGameStart ~= nil then
    Events.OnGameStart.Add(function()
        local ok, err = pcall(X.install)
        if not ok then print(TAG .. " install failed: " .. tostring(err)) end
    end)
end
-- other mods may wrap chat after us; keep the box pointed at the outermost wrapper for the first seconds
if Events ~= nil and Events.OnTick ~= nil then
    local n = 0
    local function tick()
        n = n + 1
        if X.__installed and n % 60 == 0 then X.repoint() end
        if n > 900 then ALifeHealth.remove(Events.OnTick, tick) end
    end
    ALifeHealth.add(Events.OnTick, "ALifeChatFix", tick)
end
print(TAG .. " loaded")
