-- A-Life NPC Overhaul 0.8.2: ONE COMMAND CHANNEL (built for multiplayer, works the same in single player).
--   Client asks:  ALifeCmd.send(player, name, args)   -> sendClientCommand(player, "ALifeNPCOverhaul", name, args) in MP,
--                                                        a direct call to the server handler in single player.
--   Server answers: ALifeCmd.reply(player, name, payload) -> sendServerCommand(...) in MP, a direct call in SP.
--   Handlers: ALifeCmd.onServer(name, fn(player, args)), ALifeCmd.onClient(name, fn(payload)).
-- Args cross the network, so only plain strings / numbers / booleans (and plain tables, 3 levels deep) are sent;
-- strings are capped. A handler that errors logs one line and is switched off for the session.
ALifeCmd = ALifeCmd or {}
local C = ALifeCmd
local TAG = "[ALifeCmd]"
C.VERSION = "0.8.2"
C.MODULE = "ALifeNPCOverhaul"
C.server = C.server or {}
C.client = C.client or {}
C.off = C.off or {}
C.metrics = C.metrics or { sent = 0, handled = 0, replied = 0, dropped = 0 }
C.MAX_STR = 300
C.MAX_KEYS = 40

local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function isMPClient() return type(isClient) == "function" and isClient() == true end
local function isMPServer() return type(isServer) == "function" and isServer() == true end

function C.onServer(name, f) C.server[name] = f end
function C.onClient(name, f) C.client[name] = f end

local function cleanValue(v, depth)
    local t = type(v)
    if t == "string" then
        if #v > C.MAX_STR then return string.sub(v, 1, C.MAX_STR) end
        return v
    end
    if t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return nil end
        return v
    end
    if t == "boolean" then return v end
    if t == "table" and depth < 3 then
        local out, n = {}, 0
        for k, x in pairs(v) do
            if n >= C.MAX_KEYS then break end
            if type(k) == "string" or type(k) == "number" then
                local c = cleanValue(x, depth + 1)
                if c ~= nil then out[k] = c; n = n + 1 end
            end
        end
        return out
    end
    return nil
end
function C.clean(args)
    if type(args) ~= "table" then return {} end
    return cleanValue(args, 0) or {}
end

local function run(kind, list, name, a, b)
    local f = list[name]
    if f == nil then C.metrics.dropped = C.metrics.dropped + 1; return false, nil end
    local key = kind .. ":" .. name
    if C.off[key] then return false, nil end
    local ok, out = pcall(f, a, b)
    if not ok then
        C.off[key] = true
        log(kind .. " handler '" .. name .. "' failed, off for this session: " .. tostring(out))
        return false, nil
    end
    return true, out
end

-- client side: ask the server
function C.send(player, name, args)
    if player == nil or type(name) ~= "string" then return false end
    args = C.clean(args)
    C.metrics.sent = C.metrics.sent + 1
    if isMPClient() then
        if type(sendClientCommand) ~= "function" then return false end
        return pcall(sendClientCommand, player, C.MODULE, name, args) == true
    end
    return C.handle(player, name, args)
end

-- server side: run a handler (from the network in MP, directly in SP)
function C.handle(player, name, args)
    C.metrics.handled = C.metrics.handled + 1
    local ok = run("server", C.server, name, player, C.clean(args))
    return ok
end

-- server side: answer one player
function C.reply(player, name, payload)
    payload = C.clean(payload)
    C.metrics.replied = C.metrics.replied + 1
    if isMPServer() then
        if type(sendServerCommand) ~= "function" or player == nil then return false end
        return pcall(sendServerCommand, player, C.MODULE, name, payload) == true
    end
    local ok = run("client", C.client, name, payload)
    return ok
end

function C.onClientCommand(module, command, player, args)
    if module ~= C.MODULE then return end
    C.handle(player, command, args)
end
function C.onServerCommand(module, command, args)
    if module ~= C.MODULE then return end
    run("client", C.client, command, C.clean(args))
end

if not C._events and type(Events) == "table" then
    C._events = true
    if Events.OnClientCommand ~= nil then Events.OnClientCommand.Add(C.onClientCommand) end
    if Events.OnServerCommand ~= nil then Events.OnServerCommand.Add(C.onServerCommand) end
end
print(TAG .. " loaded v" .. C.VERSION)
