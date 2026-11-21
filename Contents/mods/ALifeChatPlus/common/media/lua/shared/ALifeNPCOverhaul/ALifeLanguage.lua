-- A-Life NPC Overhaul 0.5.1: the language NPCs speak (sandbox: "NPC Overhaul: 2. Talk and AI" > NPC language).
-- Auto = they answer in whatever language you typed. Needs the optional AI (local or cloud): without it, typed
-- commands are understood in English only, and A-Life's own stock lines stay English.
require "ALifeNPCOverhaul/AA_Side"
local Events = ALifeSide.hooks("world", "ALifeLanguage") -- pre-1.0 MP: one side switch (world ticks where the world is; OnGameStart = OnServerStarted on a server)
ALifeLanguage = ALifeLanguage or {}
local L = ALifeLanguage
L.list = {
    { "auto", "Auto (match what you type)" }, { "en", "English" }, { "es", "Spanish" }, { "pt", "Portuguese" },
    { "fr", "French" }, { "de", "German" }, { "it", "Italian" }, { "pl", "Polish" }, { "ru", "Russian" },
    { "uk", "Ukrainian" }, { "tr", "Turkish" }, { "zh", "Chinese" }, { "ja", "Japanese" }, { "ko", "Korean" },
}
function L.code()
    local sv = type(SandboxVars) == "table" and type(SandboxVars.ALifeChatPlus) == "table" and SandboxVars.ALifeChatPlus or nil
    local i = sv and tonumber(sv.NpcLanguage) or 1
    -- 0.8.12: the setting (sandbox copy, or the AI tab's in-game choice) wins when there is one
    local m = ALifeLLMTalk
    if type(m) == "table" and type(m.settings) == "table" and tonumber(m.settings.npcLanguage) then i = tonumber(m.settings.npcLanguage) end
    local e = L.list[i] or L.list[1]
    return e[1], (e[1] == "auto" and "the newcomer's language") or e[2]
end
-- the "didn't catch that" fallback is for English garble; it must not swallow a line in another language
function L.foreign(text)
    local code = L.code()
    if code ~= "auto" and code ~= "en" then return true end
    if type(text) ~= "string" then return false end
    -- 0.8.11.2: any setting, English included: a line in another language is never English garble
    return L.looksForeign(text)
end
-- 0.8.11.2 (Kingston "Hola"): does this line look like another language, whatever the setting? Non-ASCII letters, or
-- words that are clearly not English (Spanish, Portuguese, French, German, Italian; accents often left off when
-- typing). Such a line skips the English typo fixer / keyword guesses and goes to the AI as typed.
L.markers = {}
for w in string.gmatch("hola gracias amigo amiga amigos senor senora hermano hermana buenos buenas dias tardes noches "
    .. "que como estas esta donde tienes tengo quiero necesito comida agua ayuda ayudame por favor vamos aqui ahora "
    .. "nada mucho bueno bien mal usted ustedes nosotros soy eres somos tambien porque cuando quien pero muy "
    .. "tal pasa gusta hace puedo puedes sabes hay vale claro entonces necesitas estoy "
    .. "obrigado obrigada voce tudo bem ola "
    .. "bonjour salut merci oui je suis tu es vous etes nous avec pourquoi comment ou est mon ami aide manger "
    .. "hallo danke bitte ich bin du bist nein ja wie was wer wo warum essen wasser hilfe freund "
    .. "ciao grazie sono sei dove cosa perche aiuto acqua cibo", "%S+") do L.markers[w] = true end
-- words that are also everyday English (or names) never count alone
L.markerAlsoEnglish = { ["no"] = true, ["a"] = true, ["me"] = true, ["es"] = true, ["est"] = true, ["was"] = true,
    ["is"] = true, ["bin"] = true, ["die"] = true, ["sei"] = true, ["mal"] = true, ["dove"] = true, ["ja"] = true,
    ["ole"] = true, ["tu"] = true, ["je"] = true, ["nada"] = true, ["bueno"] = true, ["amigo"] = true, ["como"] = true,
    ["mon"] = true, ["ami"] = true, ["ou"] = true, ["wie"] = true, ["wo"] = true, ["du"] = true, ["ich"] = true,
    ["sono"] = true, ["bien"] = true, ["que"] = true, ["pero"] = true, ["muy"] = true, ["por"] = true, ["ola"] = true,
    ["cosa"] = true, ["vamos"] = true, ["hallo"] = true, ["hay"] = true, ["vale"] = true }
L.strongMarkers = { hola = true, gracias = true, senor = true, senora = true, hermano = true, buenos = true, buenas = true,
    estas = true, donde = true, tienes = true, quiero = true, necesito = true, comida = true, ayuda = true, ayudame = true,
    obrigado = true, obrigada = true, voce = true, bonjour = true, salut = true, merci = true, pourquoi = true,
    danke = true, bitte = true, warum = true, wasser = true, hilfe = true, ciao = true, grazie = true, perche = true,
    aiuto = true, acqua = true, usted = true, ustedes = true, nosotros = true, tambien = true, porque = true }
function L.looksForeign(text)
    if type(text) ~= "string" or text == "" then return false end
    for i = 1, math.min(#text, 200) do
        local b = string.byte(text, i)
        if b and b > 127 then return true end
    end
    local low = string.lower(text)
    local hits, words = 0, 0
    for w in string.gmatch(low, "[%a']+") do
        words = words + 1
        if L.strongMarkers[w] then return true end
        if L.markers[w] and not L.markerAlsoEnglish[w] then hits = hits + 1 end
    end
    return hits >= 2 or (hits >= 1 and words <= 2)
end
-- push-to-talk: the helper reads this when it starts (Auto -> English: pick a language for non-English voice)
function L.writeVoiceFile()
    local code = L.code()
    local voice = (code == "auto") and "en" or code
    local w = getFileWriter("alifeai_language.txt", true, false)
    if w == nil then return false end
    w:write(voice .. "\n")
    w:close()
    return true
end
if Events ~= nil and Events.OnGameStart then
    Events.OnGameStart.Add(function()
        local ok = pcall(L.writeVoiceFile)
        local code = L.code()
        ALifeHealth.note("[ALifeLanguage]", "NPC language: " .. tostring(code) .. (ok and "" or " (voice file not written)"))
    end)
end
