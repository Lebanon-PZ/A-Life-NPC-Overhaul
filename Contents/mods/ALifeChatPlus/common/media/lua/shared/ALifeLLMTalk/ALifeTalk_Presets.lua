-- A-Life NPC Overhaul 0.8.12 (Rock List 2): SETTINGS PRESETS + a better SETTINGS SEARCH.
--   * Three buttons on the Settings page: Chill, Default, Hardcore. Each sets every setting back to the mod's default,
--     then a handful on top (Chill: no betrayals, nemeses, saboteurs, ambushes; long last warnings. Hardcore: all of
--     it, short warnings, faster thirst, a smaller party). Asks first; Save keeps it, Close without Save doesn't.
--   * The defaults are the values every module set up before your saved settings file was read (snapshot taken right
--     before M.loadSettingsFile; keys added after that are taken the first time we see them).
--   * Search: every word you type must match the setting's name, label or heading ("camp food", "warn sec").
-- Presets never touch your AI choices (those live in Zomboid\Lua\alifeai_setup.txt) or key bindings.
require "ALifeNPCOverhaul/AA_Side"
local Events, ALifeHealth = ALifeSide.hooks("ui", "ALifeTalk_Presets") -- pre-1.0 MP: one side switch (docs/PLAN-MP.md)
require "ALifeLLMTalk/ALifeLLMTalk_Main"
local M = ALifeLLMTalk
if type(M) ~= "table" then return end
local TAG = "[ALifePresets]"
M.settingDefaults = M.settingDefaults or {}

local function snapshot()
    for k, v in pairs(M.settings or {}) do
        if M.settingDefaults[k] == nil and (type(v) == "boolean" or type(v) == "number" or type(v) == "string") then M.settingDefaults[k] = v end
    end
end
-- before the saved file is read: wrap the loader (outermost, so this runs first)
local function wrapLoader()
    if M._presetWrapped or type(M.loadSettingsFile) ~= "function" then return M._presetWrapped == true end
    local orig = M.loadSettingsFile
    M.loadSettingsFile = function(...) snapshot(); M._presetSnapAt = "file"; return orig(...) end
    M._presetWrapped = true
    return true
end
wrapLoader()

-- pre-1.0 (Joe: "explain what it does, and be more diverse"): each preset reaches fights, capture, people, the camp,
-- raids, the region, tasks and survival, and `tip` says it in plain words. Every value is one of the row's own steps.
M.settingPresets = {
    chill = { label = "Chill",
        tip = "A gentler world. Fights: no betrayals, nemeses, saboteurs or ambushes; enemies don't hunt you or yell the dead onto you; plain A-Life fight smarts and beaten groups usually give up. Captured: rarely, never beaten, talking your way out works more. People: forgive more, remember your talks for a month, thank you more for favours. Camp: fewer tantrums and fistfights, more inspired days, faster skill growth. Raids: rarer, nobody listens on your walkie. Region boss: 3 strikes, forgets in 2 weeks. Tasks pay more. Slower thirst, bigger half rations, long last warnings.",
        set = { betrayal = false, nemesis = false, saboteur = false, ambush = false, ambushChance = 10, enemyHunt = false, enemyHuntMin = 30,
            enemyLure = false, enemyLureChance = 0, fightPreset = 1, giveUpChance = 75, feintChance = 10, fakeRunChance = 10, carBlockChance = 25,
            captureBeat = false, captureSurrender = 0, captureEscape = 30, captureTalkOut = 20, lastStandChance = 90, npcBaseDanger = false,
            talkPushCost = 0, askForgotCost = 0, askThanks = 8, rememberDays = 30,
            brkChance = 2, fistChance = 2, inspChance = 40, growDays = 3, teachXp = 16,
            worthMaxMul = 100, worthHiddenMul = 25, walkieScanChance = 0, walkieRaidBump = 0,
            regionRuleStrikes = 3, regionRuleForgetDays = 14, questPayScale = 1.5, storyWarnLeak = 0, standoffHaggle = 75, standoffJumpy = 0,
            underFirePanic = 6, thirstPerH = 0.03, rationHalf = 60, capTrustShare = 40, capFoodDays = 1,
            attackLastWarnSec = 12, attackLastWarnLeave = 4 } },
    default = { label = "Default", tip = "Every setting back to the mod's own default: the world as it was designed.", set = {} },
    hardcore = { label = "Hardcore",
        tip = "A mean world. Fights: betrayals, nemeses, saboteurs; anyone may ambush you, fake a retreat or block your car; brutal fight smarts, beaten groups rarely give up and hunt you for hours, yelling the dead onto you; near misses panic you more. Captured: surrender often means capture, with beatings; talking out rarely works. People: hold it against you, forget your talks in days, barely thank you. Camp: more tantrums and fistfights, few inspired days, slow skill growth. Raids: more often, hostiles listen on your walkie. Region boss: one strike, remembers 2 months. Tasks pay little. Faster thirst, thin half rations, a party of 4 that needs real trust and food, short last warnings with no red note, hover line only on a key.",
        set = { betrayal = true, nemesis = true, saboteur = true, ambush = true, ambushChance = 40, ambushWho = 3, enemyHunt = true, enemyHuntMin = 180,
            enemyLure = true, enemyLureChance = 60, fightPreset = 3, giveUpChance = 0, feintChance = 50, fakeRunChance = 50, fakeRunWho = 3, carBlockChance = 75,
            captureBeat = true, captureSurrender = 60, captureEscape = 80, captureTalkOut = 0, lastStandChance = 25, npcBaseDanger = true,
            talkPushCost = 5, askForgotCost = 3, askThanks = 2, rememberDays = 3,
            brkChance = 10, fistChance = 8, inspChance = 10, growDays = 10, teachXp = 4,
            worthMaxMul = 300, worthHiddenMul = 75, walkieScanChance = 30, walkieRaidBump = 60,
            regionRuleStrikes = 1, regionRuleForgetDays = 60, questPayScale = 0.5, storyWarnLeak = 60, standoffHaggle = 25, standoffJumpy = 100,
            underFirePanic = 20, thirstPerH = 0.08, rationHalf = 30, partyCap = 4, capTrustShare = 75, capFoodDays = 7,
            attackLastWarnSec = 3, attackLastWarnLeave = 10, attackLastWarnNote = false, hoverKeyOnly = true } },
}
M.settingPresetOrder = { "chill", "default", "hardcore" }
-- keys a preset never touches
M.settingPresetKeep = { immersive = true, enabled = true, uiStyle = true, tipsOn = true, tipShowMs = true, tipHideMs = true } -- pre-1.0: looks and hover tips are yours

-- apply: every known setting to its default, then the preset's own. Returns how many changed.
function M.settingPresetApply(id)
    local p = M.settingPresets[id]
    if p == nil then return 0 end
    snapshot()
    local known = {}
    for _, k in ipairs(M.fileKeys or {}) do known[k] = true end
    for _, r in ipairs(M.settingRows or {}) do known[r[1]] = true end
    for k in pairs(p.set) do known[k] = true end
    local n = 0
    for k in pairs(known) do
        if not M.settingPresetKeep[k] and string.sub(k, 1, 4) ~= "ptt" then
            local want = p.set[k]
            if want == nil then want = M.settingDefaults[k] end
            if want ~= nil and M.settings[k] ~= want then M.settings[k] = want; n = n + 1 end
        end
    end
    M.settingPresetLast = id
    if M.applySettings then pcall(M.applySettings) end
    print(TAG .. " preset " .. id .. ": " .. n .. " settings changed")
    return n
end

-- 0.8.12 (Rock List 2, translations): a setting's label and a heading in the player's language (Translate/<LANG>/
-- IG_UI.json keys IGUI_ALCP_Set_<key> and IGUI_ALCP_Cat_<heading>), English from the code when there's none.
local function tkey(s) return (string.gsub(tostring(s or ""), "[^%w]+", "_")) end
function M.settingLabel(row)
    if type(ALifeTr) ~= "function" then return tostring(row[2]) end
    return ALifeTr("IGUI_ALCP_Set_" .. tostring(row[1]), tostring(row[2]))
end
function M.settingCatLabel(cat)
    if type(ALifeTr) ~= "function" then return tostring(cat) end
    return ALifeTr("IGUI_ALCP_Cat_" .. tkey(cat), tostring(cat))
end
-- search: every word must be somewhere in the key, the label or the heading
function M.settingMatch(row, q)
    q = string.lower(tostring(q or ""))
    if string.match(q, "^%s*$") then return true end
    local cat = M.settingCategory and M.settingCategory(row) or ""
    local hay = string.lower(tostring(row[1]) .. " " .. tostring(row[2]) .. " " .. tostring(cat) .. " " .. M.settingLabel(row) .. " " .. M.settingCatLabel(cat))
    for w in string.gmatch(q, "%S+") do
        if not string.find(hay, w, 1, true) then return false end
    end
    return true
end

-- pre-1.0 (Joe): the presets and the window style as two drop-downs right of the search box, in plain sight.
-- Picking a preset asks first (it says what it does); picking a style changes every A-Life window at once.
local function setOne(key, v)
    M.settings[key] = v
    if M.sbTouch then pcall(M.sbTouch, key) end
    if type(ALifeSettingsNet) == "table" and type(ALifeSettingsNet.set) == "function" then pcall(ALifeSettingsNet.set, nil, key, v) end
    if M.applySettings then pcall(M.applySettings) end
end
M.settingSetOne = setOne
local function tw(f, s) local w = 8 * #tostring(s); pcall(function() w = getTextManager():MeasureStringX(f, tostring(s)) end); return w end
local function trx(k, en) if type(ALifeTr) == "function" then return ALifeTr(k, en) end return en end
local function addLabel(win, x, y, h, text, f)
    local l = ISLabel:new(x, y, h, text, 0.95, 0.85, 0.6, 1, f, true)
    l:initialise()
    win:addChild(l)
    return l
end
local function addCombo(win, x, y, w, h, f, names, sel, onPick, tip)
    local cb = ISComboBox:new(x, y, w, h, win, function(target, box) onPick(box.selected, box) end)
    cb:initialise()
    cb.font = f
    for _, n in ipairs(names) do cb:addOption(n) end
    cb.selected = sel
    win:addChild(cb)
    if type(AA_Tip) == "table" and type(AA_Tip.combo) == "function" then AA_Tip.combo(cb, tip) end
    return cb
end
function M.settingPresetTip()
    local out = { trx("IGUI_ALCP_Tip_Presets", "Presets change many settings at once. Your window style, hover tips, AI choices and keys are kept. Press Save after to keep it.") }
    for _, id in ipairs(M.settingPresetOrder) do
        local p = M.settingPresets[id]
        out[#out + 1] = trx("IGUI_ALCP_Preset_" .. id, p.label) .. ": " .. trx("IGUI_ALCP_PresetTip_" .. id, p.tip)
    end
    return table.concat(out, " <LINE> <LINE> ")
end
function M.settingStyleTip()
    return trx("IGUI_ALCP_Tip_UIStyle", "How every A-Life window looks. Changes at once. <LINE> Overhaul: our own look. <LINE> A-Life: Project A-Life's own look and colours (follows A-Life's theme). <LINE> CleanUI: like the CleanUI mod. <LINE> Vanilla: the game's own windows.")
end
function M.settingPresetButtons(win)
    local T, S = M.Theme, M.UIStyle
    if win == nil or win.search == nil or T == nil or type(ISComboBox) ~= "table" then return end
    local f = win.search.font or (S and S.font) or UIFont.Small
    local h, y = win.search:getHeight(), win.search:getY()
    -- preset names: "Custom" first (what you have now), then the presets
    local pNames, pIds = { trx("IGUI_ALCP_Preset_custom", "Custom") }, { false }
    for _, id in ipairs(M.settingPresetOrder) do pNames[#pNames + 1] = trx("IGUI_ALCP_Preset_" .. id, M.settingPresets[id].label); pIds[#pIds + 1] = id end
    local St = M.UIStyles
    local sNames = (type(St) == "table" and type(St.NAMES) == "table") and St.NAMES or nil
    local function widest(list) local w = 0; for _, n in ipairs(list) do w = math.max(w, tw(f, n)) end; return w + 44 end
    local labP, labS = trx("IGUI_ALCP_Lbl_Preset", "Preset"), trx("IGUI_ALCP_Lbl_UIStyle", "Window style")
    local preW = widest(pNames)
    local styW = sNames and widest(sNames) or 0
    local need = tw(f, labP) + 6 + preW + (sNames and (18 + tw(f, labS) + 6 + styW) or 0)
    local searchW = math.max(140, math.min(300, win.width - 24 - 16 - need))
    pcall(function() win.search:setWidth(searchW) end)
    local x = win.search:getX() + searchW + 16
    -- presets
    addLabel(win, x, y, h, labP, f); x = x + tw(f, labP) + 6
    local sel = 1
    for i, id in ipairs(pIds) do if id and id == M.settingPresetLast then sel = i end end
    local pc
    pc = addCombo(win, x, y, preW, h, f, pNames, sel, function(i)
        local id = pIds[i]
        local before = pc.alcpSel or 1
        pc.selected = before -- stays as it was until you say yes
        if not id then return end
        local p = M.settingPresets[id]
        local name = pNames[i]
        local text = trx("IGUI_ALCP_PresetAsk", "Use the {1} preset?"):gsub("{1}", name) .. " <LINE> " .. trx("IGUI_ALCP_PresetTip_" .. id, p.tip)
            .. " <LINE> " .. trx("IGUI_ALCP_PresetAsk2", "Your other choices go back to default. Press Save after to keep it.")
        local function go()
            local n = M.settingPresetApply(id)
            pc.selected, pc.alcpSel = i, i
            if M.momToast then pcall(M.momToast, name .. ": " .. n .. " " .. trx("IGUI_ALCP_PresetDone", "settings changed. Press Save to keep it.")) end
            pcall(function() win.list:layout() end)
        end
        if T.confirm then T.confirm(text, go) else go() end
    end, M.settingPresetTip)
    pc.alcpSel = sel
    win.presetCombo = pc
    x = x + preW + 18
    -- window style
    if sNames then
        addLabel(win, x, y, h, labS, f); x = x + tw(f, labS) + 6
        win.styleCombo = addCombo(win, x, y, styW, h, f, sNames, St.index(), function(i)
            setOne("uiStyle", i)
            if M.momToast then pcall(M.momToast, labS .. ": " .. tostring(sNames[i])) end
        end, M.settingStyleTip)
    end
end
function M.settingPresetInstall()
    wrapLoader()
    snapshot() -- keys registered at game start, after the file
    local ST = ALifeTalkSettings
    if type(ST) == "table" and type(ST.createChildren) == "function" and not ST._presetHooked then
        local orig = ST.createChildren
        ST.createChildren = function(self, ...)
            local r = orig(self, ...)
            pcall(M.settingPresetButtons, self)
            return r
        end
        ST._presetHooked = true
    end
    print(TAG .. " ready pre-1.0: presets Chill / Default / Hardcore + window style (drop-downs, " .. tostring(M._presetSnapAt or "late") .. " defaults), word search")
end
if type(Events) == "table" and Events.OnGameStart ~= nil then Events.OnGameStart.Add(function() pcall(M.settingPresetInstall) end) end
return M
