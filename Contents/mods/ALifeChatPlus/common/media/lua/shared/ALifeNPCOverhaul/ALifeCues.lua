-- A-Life NPC Overhaul 0.8.12 (Rock List 2): CUES. Words, never numbers, for how someone is toward you and how your
-- people are doing. Used by the hover cue (ALifeTalk_Hover.lua: over their head, on the quick wheel target, at the top
-- of the talk window: the same words everywhere) and by the Party tab (ALifeLLMTalk_PartyUI.lua).
-- Server side (or single player): "hoverAsk" { uid } -> "hoverFacts" { uid, stance, why, band, armed, gun, weapon }.
-- A-Life's Relations / NpcOpinion / ActorRegistry live in server/, so in multiplayer only the server can read them.
-- The server only answers for someone near the asking player (hoverRange + 5 tiles): no reading people across the map.
-- Words come from plain tables of facts, so the same lines show in single player and multiplayer.
require "ALifeNPCOverhaul/ALifeCmd"

ALifeCues = ALifeCues or {}
local U = ALifeCues
local TAG = "[ALifeCues]"
U.VERSION = "0.9.0"
U.DEFAULTS = {
    hoverCue = true,        -- a short line over someone's head when your mouse rests on them
    hoverKeyOnly = false,   -- only while the hover key is held (Options > Mods > A-Life NPC Overhaul)
    hoverDelayMs = 500,     -- how long the mouse rests on them first (passing over = nothing)
    hoverRange = 15,        -- tiles: only people this close
    hoverStickMs = 1500,    -- the line stays this long after the mouse leaves (a walking NPC doesn't blink)
    hoverPickTiles = 1.3,   -- how close to them the mouse has to be (tiles)
    hoverAskMs = 4000,      -- read them again after this long (ms)
    hoverWhyMin = 20,       -- a refusal ("won't come along: ...") shows this many real minutes
    hoverHeadPx = 120,      -- how high over their feet the line sits (screen pixels at normal zoom)
    hoverWheel = true,      -- the same line over whoever the quick wheel is for
    hoverTalkTop = true,    -- the same line at the top of the talk window
    partyNeedLow = 25,      -- Party tab: hunger / thirst (0-100) from here = "peckish" / "dry"
    partyNeedBad = 55,      -- = "hungry" / "thirsty"
    partyNeedUrgent = 80,   -- = "starving" / "parched" (red)
    partyAmmoLow = 6,       -- rounds left (in the gun + carried) at or below this = "low on ammo"
    talkKeyTiles = 4,       -- the talk key: how close the nearest person must be (tiles)
    attackLastWarn = true,  -- a last warning before someone attacks you (when a real person would give one)
    attackLastWarnSec = 5,  -- seconds to walk away after it (the clock stops while paused)
    attackLastWarnLeave = 6, -- tiles further away that count as walking away
    attackLastWarnNote = true, -- the warning on screen too (red note over you + a red letter)
    partyCards = true,      -- Party tab as cards (figure in their clothes, facts, a short journal); off = the old list
    partyAvatars = 6,       -- how many 3D figures at once on the Party tab (0 = none; each one costs a little)
    partyJournal = 3,       -- lines of their journal on each card
}

local function fn(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function PA() return type(ProjectALife) == "table" and ProjectALife or {} end
local function tr(k, en, ...)
    if ALifeTr then return ALifeTr("IGUI_ALCP_Cue_" .. k, en, ...) end
    local a = { ... }
    return (string.gsub(en, "{(%d)}", function(i) return tostring(a[tonumber(i)] or "") end))
end
U.tr = tr

function U.setting(key)
    local m = ALifeLLMTalk
    local v = nil
    if type(m) == "table" and type(m.settings) == "table" then v = m.settings[key] end
    if v == nil then v = U.DEFAULTS[key] end
    return v
end
-- new keys go in the settings file list at load time (or they reset on restart): called from the client file
function U.registerSettings()
    local m = ALifeLLMTalk
    if type(m) ~= "table" or type(m.settings) ~= "table" then return false end
    m.fileKeys = m.fileKeys or {}
    for k, v in pairs(U.DEFAULTS) do
        if m.settings[k] == nil then m.settings[k] = v end
        local have = false
        for _, x in ipairs(m.fileKeys) do if x == k then have = true end end
        if not have then m.fileKeys[#m.fileKeys + 1] = k end
    end
    return true
end
local function num(key) local v = tonumber(U.setting(key)); if v == nil then v = U.DEFAULTS[key] end; return v end

----------------------------------------------------------------------------------------------------------------
-- words (pure)
----------------------------------------------------------------------------------------------------------------
-- opinion (-100..100) -> a band id. Same cut points as the People page's mood words.
function U.band(op)
    op = tonumber(op)
    if op == nil then return "unknown" end
    if op <= -41 then return "hate" elseif op <= -16 then return "wary" elseif op < 16 then return "unsure"
    elseif op < 41 then return "okay" elseif op < 71 then return "like" end
    return "trust"
end
U.BAND_WORDS = { hate = "Hates you.", wary = "Wary of you.", unsure = "Doesn't know what to make of you.",
    okay = "Friendly enough.", like = "Likes you.", trust = "Trusts you." }
-- why they're hostile (ALifeTalkPatch.calmThreshold's reason) -> words
U.WHY_WORDS = { grudge = "Out for you. They haven't forgotten.", nemesis = "Came back to settle it with you.",
    hostile_act = "Bad blood: you hurt them or theirs.", reputation = "Your name is poison to them.",
    faction = "Their people count you as an enemy.", checkpoint = "Guarding this place. Turn back.",
    ordered = "Told to treat you as an enemy.", forced = "Hostile." }
U.TONES = { hostile = { 0.92, 0.42, 0.35 }, wary = { 0.95, 0.72, 0.35 }, plain = { 0.88, 0.86, 0.8 }, warm = { 0.6, 0.85, 0.55 } }

-- what's in their hand, for the second line
function U.armWord(f)
    if type(f) ~= "table" or f.armed ~= true then return nil end
    local what = type(f.weapon) == "string" and f.weapon ~= "" and string.lower(f.weapon) or (f.gun and "gun" or "weapon")
    if f.stance == "hostile" then
        if f.gun then return tr("GunUp", "Gun in hand: {1}.", what) end
        return tr("HandOn", "Hand on the {1}.", what)
    end
    if f.band == "hate" or f.band == "wary" then return tr("HandNear", "Hand near the {1}.", what) end
    return nil
end

-- the one or two lines. f = facts (server) + client bits: party (with you), refused { what, why }, mood (adjective).
-- returns lines, tone
function U.lines(f)
    if type(f) ~= "table" then return {}, "plain" end
    local out, tone = {}, "plain"
    if f.lastWarn then
        out[1] = tr("LastWarn", "About to attack you. Walk away.")
        tone = "hostile"
    elseif f.stance == "hostile" then
        out[1] = tr("Why_" .. tostring(f.why or "forced"), U.WHY_WORDS[tostring(f.why or "forced")] or U.WHY_WORDS.forced)
        tone = "hostile"
    elseif f.party then
        local b = f.band
        if b == "hate" or b == "wary" then out[1] = tr("PartySour", "With you, but not happy about it."); tone = "wary"
        else out[1] = tr("Party", "With you."); tone = "warm" end
    elseif f.band ~= nil and f.band ~= "unknown" then
        out[1] = tr("Band_" .. f.band, U.BAND_WORDS[f.band] or U.BAND_WORDS.unsure)
        if f.band == "hate" or f.band == "wary" then tone = "wary" elseif f.band == "like" or f.band == "trust" then tone = "warm" end
    end
    local second = nil
    if type(f.refused) == "table" and f.refused.what then
        second = tr("Refused", "Won't {1}: {2}.", tostring(f.refused.what), tostring(f.refused.why or "won't say why"))
    end
    second = second or U.armWord(f)
    if second == nil and type(f.mood) == "string" and f.mood ~= "" and f.stance ~= "hostile" then
        second = tr("Mood", "Seems {1}.", f.mood)
    end
    if second then out[#out + 1] = second end
    return out, tone
end

-- Party tab: hunger / thirst (0-100) -> word, tone (nil word = fine)
U.NEED_WORDS = { hunger = { "peckish", "hungry", "starving" }, thirst = { "dry", "thirsty", "parched" } }
function U.needWord(kind, v)
    v = tonumber(v)
    local w = U.NEED_WORDS[kind]
    if v == nil or w == nil then return nil, nil end
    if v >= num("partyNeedUrgent") then return tr("Need_" .. kind .. "3", w[3]), "red" end
    if v >= num("partyNeedBad") then return tr("Need_" .. kind .. "2", w[2]), "amber" end
    if v >= num("partyNeedLow") then return tr("Need_" .. kind .. "1", w[1]), "dim" end
    return nil, nil
end
-- 0..100 health -> word, tone
function U.hpWord(hp)
    hp = tonumber(hp) or 100
    if hp >= 90 then return tr("Hp1", "unhurt"), "green" end
    if hp >= 65 then return tr("Hp2", "scratched up"), "green" end
    if hp >= 35 then return tr("Hp3", "hurt"), "amber" end
    return tr("Hp4", "badly hurt"), "red"
end
-- gear table { weapon, gun, ammo, bag } -> one short line
function U.gearLine(g)
    if type(g) ~= "table" then return tr("GearNone", "empty-handed") end
    local parts = {}
    if type(g.weapon) == "string" and g.weapon ~= "" then
        local w = g.weapon
        if g.gun and tonumber(g.ammo) ~= nil then
            if tonumber(g.ammo) <= 0 then w = w .. " " .. tr("AmmoOut", "(out of ammo)")
            elseif tonumber(g.ammo) <= num("partyAmmoLow") then w = w .. " " .. tr("AmmoLow", "(low on ammo)") end
        end
        parts[#parts + 1] = w
    else
        parts[#parts + 1] = tr("GearNone", "empty-handed")
    end
    if type(g.bag) == "string" and g.bag ~= "" then parts[#parts + 1] = g.bag end
    -- pre-1.0 melee style: their kind, in words (ALifeMeleeStyle.cueFor; never a number)
    if type(g.knows) == "string" and g.knows ~= "" then parts[#parts + 1] = tr("GoodWith", "good with {1}", tr("MStyle_" .. g.knows, g.knowsWord or g.knows)) end
    return table.concat(parts, ", ")
end

----------------------------------------------------------------------------------------------------------------
-- facts (server, or single player)
----------------------------------------------------------------------------------------------------------------
local function shellOf(uid)
    local pa = PA()
    if fn(pa.Companions, "shellOf") then local ok, sh = pcall(pa.Companions.shellOf, uid); if ok and sh then return sh end end
    if fn(pa.Talk, "shellFor") then local ok, sh = pcall(pa.Talk.shellFor, uid); if ok and sh then return sh end end
    return nil
end
U.shellOf = shellOf
-- the weapon a shell carries: A-Life's own Weapons.current (server/ALifeWeapons.lua; their "is it a gun" test is
-- getMaxAmmo() > 0, as CompanionSheetServer.weaponFacts), else the vanilla hand slot (multiplayer client; unverified
-- on A-Life shells). Returns the item or nil.
function U.weaponItem(sh)
    if sh == nil then return nil end
    local W = PA().Weapons
    if fn(W, "current") then local ok, it = pcall(W.current, sh); if ok and it ~= nil then return it end end
    local it = nil
    pcall(function()
        local h = sh:getPrimaryHandItem()
        if h ~= nil and (instanceof == nil or instanceof(h, "HandWeapon")) then it = h end
    end)
    return it
end
-- what's in a shell's hands: name, is it a gun
function U.handOf(sh)
    local it = U.weaponItem(sh)
    if it == nil then return nil, false end
    local name, gun = nil, false
    pcall(function() name = it:getDisplayName() end)
    pcall(function() local m = tonumber(it:getMaxAmmo()); gun = m ~= nil and m > 0 end)
    if name == nil then return nil, false end
    return tostring(name), gun
end
-- gear for the Party tab: { weapon, gun, ammo (loaded + carried, guns only, nil = unknown), bag }
function U.gearOf(sh)
    local g = {}
    if sh == nil then return g end
    local it = U.weaponItem(sh)
    g.weapon, g.gun = U.handOf(sh)
    if g.gun and it ~= nil then
        local loaded = nil
        pcall(function() loaded = tonumber(it:getCurrentAmmoCount()) end)
        local spare = nil
        local mags, W = PA().MagazineState, PA().Weapons
        if fn(mags, "reserve") then
            local slot = fn(W, "slot") and select(2, pcall(W.slot, it)) or nil
            local ok, rounds = pcall(mags.reserve, sh, slot, it)
            if ok and type(rounds) == "number" then spare = rounds end
        end
        if loaded ~= nil then g.ammo = loaded + (spare or 0) end
    end
    if type(ALifeMeleeStyle) == "table" and fn(ALifeMeleeStyle, "cueKind") then -- pre-1.0: "good with knives"
        local ok, k = pcall(ALifeMeleeStyle.cueKind, sh)
        if ok and type(k) == "string" then g.knows, g.knowsWord = k, ALifeMeleeStyle.WORD[k] end
    end
    pcall(function() -- the bag they wear (CompanionSheetServer.bagName: the first worn InventoryContainer)
        local worn = sh:getWornItems()
        for i = 0, worn:size() - 1 do
            local item = worn:get(i):getItem()
            if g.bag == nil and item ~= nil and instanceof(item, "InventoryContainer") then g.bag = tostring(item:getDisplayName()) end
        end
    end)
    return g
end
-- what a shell is wearing right now (vanilla getWornItems), bag left out (gear shows it). Short names, max n.
function U.wornOf(sh, n)
    local out = {}
    if sh == nil then return out end
    n = tonumber(n) or 8
    pcall(function()
        local worn = sh:getWornItems()
        for i = 0, worn:size() - 1 do
            local item = worn:get(i):getItem()
            if item ~= nil and #out < n and not instanceof(item, "InventoryContainer") then
                local name = tostring(item:getDisplayName())
                local dup = false
                for _, o in ipairs(out) do if o == name then dup = true end end
                if not dup then out[#out + 1] = name end
            end
        end
    end)
    return out
end
function U.facts(player, uid)
    uid = tostring(uid or "")
    if player == nil or uid == "" then return nil, "bad" end
    local pa = PA()
    if not fn(pa.ActorRegistry, "read") then return nil, "no_alife" end
    local okR, r = pcall(pa.ActorRegistry.read, uid)
    if not okR or type(r) ~= "table" or r.lifecycle == "dead" then return nil, "gone" end
    local sh = shellOf(uid)
    local x, y = nil, nil
    if sh then pcall(function() x, y = sh:getX(), sh:getY() end) end
    if x == nil and type(r.worldPosition) == "table" then x, y = tonumber(r.worldPosition.x), tonumber(r.worldPosition.y) end
    local px, py = nil, nil
    pcall(function() px, py = player:getX(), player:getY() end)
    local reach = num("hoverRange") + 5
    if x == nil or px == nil or (x - px) ^ 2 + (y - py) ^ 2 > reach * reach then return nil, "far" end
    local f = { uid = uid, stance = "neutral", band = "unknown" }
    if fn(pa.Relations, "playerStance") then
        local ok, st = pcall(pa.Relations.playerStance, r, player)
        if ok and type(st) == "string" then f.stance = st end
    end
    if f.stance == "hostile" then
        f.why = "faction"
        local P = ALifeTalkPatch
        if fn(P, "calmThreshold") then
            local ok, _, why = pcall(P.calmThreshold, r, player)
            if ok and type(why) == "string" then f.why = why end
        end
    end
    if fn(pa.NpcOpinion, "valueOf") then
        local ok, v = pcall(pa.NpcOpinion.valueOf, r, player)
        if ok and tonumber(v) then f.band = U.band(tonumber(v)) end
    end
    local wname, gun = U.handOf(sh)
    if wname then f.armed, f.weapon, f.gun = true, string.sub(tostring(wname), 1, 40), gun == true end
    return f
end

----------------------------------------------------------------------------------------------------------------
-- the command
----------------------------------------------------------------------------------------------------------------
function U.install()
    if U.installed or type(ALifeCmd) ~= "table" or not fn(ALifeCmd, "onServer") then return U.installed == true end
    ALifeCmd.onServer("hoverAsk", function(player, args)
        if type(args) ~= "table" or args.uid == nil then return end
        local uid = string.sub(tostring(args.uid), 1, 64)
        local ok, f, why = pcall(U.facts, player, uid)
        if not ok then print(TAG .. " facts failed: " .. tostring(f)); f, why = nil, "error" end
        if type(f) ~= "table" then ALifeCmd.reply(player, "hoverFacts", { uid = uid, none = true, why = tostring(why or "none") }); return end
        ALifeCmd.reply(player, "hoverFacts", f)
    end)
    U.installed = true
    return true
end
U.install()
print(TAG .. " ready v" .. U.VERSION .. ": hover cue + party words (hoverAsk -> hoverFacts)")
return U
