-- A-Life Talk 0.5.1.5: FAR-AWAY LOOK - the full-body preview in the Relationships window stays when the NPC is far.
-- Why: the preview was ISUI3DModel:setCharacter(<the NPC's IsoZombie body>). Far away / unloaded there is no body,
-- so the box was empty. Now, while a known NPC is loaded, we save their look in the people book (ModData, bucket
-- "book", field "look"): gender, skin, hair + colour, beard + colour, worn clothing types + tints (A-Life's own list
-- when the body has it, else the worn item visuals), the outfit name. With no body the preview is rebuilt from that
-- save as a SurvivorDesc (the same thing the vanilla / A-Life character creator shows: SurvivorFactory.CreateSurvivor
-- + ISUI3DModel:setSurvivorDesc) - nothing is spawned in the world. If that can't be drawn, the box shows the last
-- captured look as text. A small "Last seen ..." tag sits under the preview. Setting "farLook" turns it off.
-- Removable: without this file the preview behaves as in 0.5.1.4 (body only).
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("world", "ALifeLLMTalk_Look") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
if type(ALifeLLMTalk) == "table" then ALifeLLMTalk._file = "Look"; if ALifeLLMTalk.fileBegin then ALifeLLMTalk.fileBegin("Look") end end -- 0.5.1.6 perf label

local M = ALifeLLMTalk
if type(M) ~= "table" then return end
local function PA() return type(ProjectALife) == "table" and ProjectALife or nil end
local function fn(t, name) return type(t) == "table" and type(t[name]) == "function" end
local function has(o, name) local ok, r = pcall(function() return type(o[name]) == "function" end); return ok and r end
local function hours() local h = 0; pcall(function() h = getGameTime():getWorldAgeHours() end); return h end

if M.settings.farLook == nil then M.settings.farLook = true end
if type(M.fileKeys) == "table" then
    local have = false
    for _, x in ipairs(M.fileKeys) do if x == "farLook" then have = true end end
    if not have then M.fileKeys[#M.fileKeys + 1] = "farLook" end
end
M.lookCfg = { everyMs = 60000, maxItems = 24 }
M.lookAt = M.lookAt or {}
M.lookStats = M.lookStats or { saved = 0, built = 0, failed = 0 }

local function colorOf(c)
    if c == nil then return nil end
    local out = nil
    pcall(function()
        if has(c, "getRedFloat") then out = { c:getRedFloat(), c:getGreenFloat(), c:getBlueFloat() }
        elseif has(c, "getR") then out = { c:getR(), c:getG(), c:getB() } end
    end)
    return out
end
local function shellOf(uid)
    local pa = PA()
    local sh = nil
    pcall(function() if pa and fn(pa.Talk, "shellFor") then sh = pa.Talk.shellFor(tostring(uid)) end end)
    return sh
end
M.lookShellOf = shellOf

function M.lookOf(uid)
    local e = M.bucket("book")[tostring(uid)]
    return (type(e) == "table" and type(e.look) == "table") and e.look or nil
end

-- read the look off a loaded body (an IsoZombie shell); nil if nothing readable
function M.lookRead(shell)
    if shell == nil then return nil end
    local L = { cloth = {}, tints = {} }
    local got = false
    pcall(function() if has(shell, "isFemale") then L.female = shell:isFemale() == true; got = true end end)
    pcall(function()
        local hv = has(shell, "getHumanVisual") and shell:getHumanVisual() or nil
        if hv == nil then return end
        if has(hv, "getSkinTextureIndex") then L.skin = tonumber(hv:getSkinTextureIndex()) end
        if has(hv, "getSkinTexture") then local s = hv:getSkinTexture(); if s ~= nil then L.skinTex = tostring(s) end end
        if has(hv, "getHairModel") then L.hair = tostring(hv:getHairModel() or "") end
        if has(hv, "getBeardModel") then L.beard = tostring(hv:getBeardModel() or "") end
        if has(hv, "getHairColor") then L.hairColor = colorOf(hv:getHairColor()) end
        if has(hv, "getBeardColor") then L.beardColor = colorOf(hv:getBeardColor()) end
        got = true
    end)
    pcall(function()
        local data = has(shell, "getModData") and shell:getModData() or nil
        if type(data) ~= "table" then return end
        if type(data.ProjectALifeClothingTypes) == "table" then
            for i, t in ipairs(data.ProjectALifeClothingTypes) do
                if i > M.lookCfg.maxItems then break end
                L.cloth[#L.cloth + 1] = tostring(t)
                L.tints[#L.tints + 1] = type(data.ProjectALifeClothingTints) == "table" and tostring(data.ProjectALifeClothingTints[i] or "") or ""
            end
        end
        L.seed = data.ProjectALifeAppearanceSeed and tostring(data.ProjectALifeAppearanceSeed) or nil
        if L.female == nil and data.ProjectALifeFemale ~= nil then L.female = data.ProjectALifeFemale == true end
    end)
    if #L.cloth == 0 then -- not an A-Life dressed body: the worn item visuals
        pcall(function()
            local iv = has(shell, "getItemVisuals") and shell:getItemVisuals() or nil
            if iv == nil then return end
            for i = 0, math.min(iv:size(), M.lookCfg.maxItems) - 1 do
                local v = iv:get(i)
                local t = v and has(v, "getItemType") and v:getItemType() or nil
                if t ~= nil then L.cloth[#L.cloth + 1] = tostring(t); L.tints[#L.tints + 1] = "" end
            end
        end)
    end
    pcall(function() if has(shell, "getOutfitName") then local o = shell:getOutfitName(); if o ~= nil then L.outfit = tostring(o) end end end)
    if #L.cloth > 0 then got = true end
    if not got then return nil end
    return L
end

-- save the look of a known person (book entry needed). force = ignore the 60 s gap
function M.lookSave(uid, shell, force)
    if M.settings.farLook == false or uid == nil then return nil end
    uid = tostring(uid)
    local e = M.bucket("book")[uid]
    if type(e) ~= "table" then return nil end
    if not force and e.look ~= nil and (M.nowMs() - (M.lookAt[uid] or -1e12)) < M.lookCfg.everyMs then return e.look end
    shell = shell or shellOf(uid)
    local L = M.lookRead(shell)
    M.lookAt[uid] = M.nowMs()
    if L == nil then return e.look end
    L.h = hours()
    if e.look == nil then
        M.keepLog("look: saved " .. tostring(e.name or uid) .. "'s appearance (" .. #L.cloth .. " items) for the far-away preview", "look|" .. uid, 1e12)
    end
    e.look = L
    M.lookStats.saved = M.lookStats.saved + 1
    return L
end

local function applyColor(hv, rgb, beard)
    if type(rgb) ~= "table" or ImmutableColor == nil or not fn(ImmutableColor, "new") then return end
    pcall(function()
        local c = ImmutableColor.new(tonumber(rgb[1]) or 0, tonumber(rgb[2]) or 0, tonumber(rgb[3]) or 0, 1)
        if beard then if has(hv, "setBeardColor") then hv:setBeardColor(c) end
        elseif has(hv, "setHairColor") then hv:setHairColor(c) end
    end)
end

-- a stand-in SurvivorDesc from a saved look (UI only, never added to the world)
function M.lookDesc(L)
    if type(L) ~= "table" then return nil end
    if type(SurvivorFactory) ~= "table" and type(SurvivorFactory) ~= "userdata" then return nil end
    local ok, desc = pcall(function() return SurvivorFactory.CreateSurvivor(SurvivorType.Neutral, L.female == true) end)
    if not ok or desc == nil then M.lookStats.failed = M.lookStats.failed + 1; return nil end
    pcall(function()
        local hv = desc:getHumanVisual()
        if hv == nil then return end
        if tonumber(L.skin) and has(hv, "setSkinTextureIndex") then hv:setSkinTextureIndex(math.max(0, math.min(4, math.floor(L.skin)))) end
        if L.skinTex and has(hv, "setSkinTextureName") then hv:setSkinTextureName(L.skinTex) end
        if has(hv, "setHairModel") then hv:setHairModel(tostring(L.hair or "")) end
        if has(hv, "setBeardModel") then hv:setBeardModel(L.female and "" or tostring(L.beard or "")) end
        applyColor(hv, L.hairColor, false)
        applyColor(hv, L.beardColor, true)
    end)
    local worn = 0
    if type(instanceItem) == "function" and has(desc, "setWornItem") then
        local hyd = PA() and PA().ProfileHydrator or nil
        for i, t in ipairs(L.cloth or {}) do
            pcall(function()
                local item = instanceItem(t)
                if item == nil then return end
                if fn(hyd, "prepareClothing") then hyd.prepareClothing(item, { itemType = t, tint = (L.tints or {})[i] ~= "" and (L.tints or {})[i] or nil }, L.seed)
                elseif has(item, "getVisual") then local v = item:getVisual(); if v and has(v, "setInventoryItem") then v:setInventoryItem(item) end end
                local where = has(item, "getBodyLocation") and item:getBodyLocation() or nil
                if (where == nil or where == "") and has(item, "canBeEquipped") then where = item:canBeEquipped() end
                if where ~= nil and where ~= "" then desc:setWornItem(where, item); worn = worn + 1 end
            end)
        end
    end
    M.lookStats.built = M.lookStats.built + 1
    return desc, worn
end

-- "Base.Jacket_Padded" -> "Jacket Padded"
local function pretty(t)
    local s = tostring(t or "")
    s = string.gsub(s, "^.*%.", "")
    s = string.gsub(s, "_", " ")
    return s
end
-- the text fallback ("last captured look"), a few short lines
function M.lookLines(L, maxLines)
    local out = {}
    if type(L) ~= "table" then return out end
    local who = (L.female == true and "Woman") or (L.female == false and "Man") or "Person"
    local hair = (L.hair and L.hair ~= "") and (pretty(L.hair) .. " hair") or "no hair seen"
    out[#out + 1] = who .. ", " .. hair
    if L.beard and L.beard ~= "" and not L.female then out[#out + 1] = pretty(L.beard) .. " beard" end
    local n = 0
    for _, t in ipairs(L.cloth or {}) do
        if #out >= (maxLines or 8) then break end
        out[#out + 1] = "- " .. pretty(t)
        n = n + 1
    end
    if n == 0 and L.outfit then out[#out + 1] = "Outfit: " .. pretty(L.outfit) end
    return out
end

-- compact "Last seen 3 h ago" for the tag under the preview (nil while they are right here)
function M.lastSeenTag(uid)
    local s = M.bucket("seen")[tostring(uid)]
    local e = M.bucket("book")[tostring(uid)]
    local h = (type(s) == "table" and s.h) or (type(e) == "table" and e.h) or nil
    if h == nil then return "Last seen: unknown" end
    local dh = math.max(0, hours() - h)
    if dh < 1 then return "Last seen < 1 h ago" end
    if dh < 48 then return "Last seen " .. math.floor(dh + 0.5) .. " h ago" end
    return "Last seen " .. math.floor(dh / 24 + 0.5) .. " days ago"
end

-- the Relationships window preview: live body, else the saved look as a stand-in, else text
-- returns mode: "live" | "standin" | "text" | "none"
function M.lookPortrait(win)
    if win == nil then return "none" end
    local uid = tostring(win.uid)
    local shell = shellOf(uid)
    if shell ~= nil then
        pcall(M.lookSave, uid, shell, false)
        if win.portraitMode == "live" and win.model ~= nil and win.portraitShell == shell then return "live" end
    end
    local L = M.settings.farLook ~= false and M.lookOf(uid) or nil
    if shell == nil and win.portraitMode ~= nil and win.portraitMode ~= "live" then
        -- already showing the stand-in / text / nothing: only rebuild when a look turned up since
        if not (win.portraitMode == "none" and L ~= nil) then return win.portraitMode end
    end
    local desc = nil
    if shell == nil then desc = M.lookDesc(L) end
    local can3d = ISUI3DModel ~= nil and (shell ~= nil or (desc ~= nil and type(ISUI3DModel.setSurvivorDesc) == "function"))
    if not can3d then
        if win.model ~= nil then pcall(function() win.model:setVisible(false) end) end
        win.portraitMode, win.portraitShell = L and "text" or "none", nil
        win.portraitLook = L
        return win.portraitMode
    end
    local okM = pcall(function()
        local m = win.model
        if m == nil then
            m = ISUI3DModel:new(win.portraitX, win.portraitY, win.portraitW, win.portraitH)
            m:initialise()
            m:instantiate()
            win:addChild(m)
            win.model = m
        end
        if shell ~= nil then
            m:setCharacter(shell)
            win.portraitMode, win.portraitShell = "live", shell
        else
            pcall(function() m:setCharacter(nil) end)
            m:setSurvivorDesc(desc)
            win.portraitMode, win.portraitShell = "standin", nil
        end
        pcall(function() m:setState("idle") end)
        pcall(function() m:setDirection(IsoDirections.S) end)
        pcall(function() m:setIsometric(false) end)
        pcall(function() m:setVisible(win.activeTab ~= 1 or not win.pageMode) end)
    end)
    if not okM then
        if win.model ~= nil then pcall(function() win.model:setVisible(false) end) end
        win.portraitMode = L and "text" or "none"
    end
    win.portraitLook = L
    return win.portraitMode
end

return M
