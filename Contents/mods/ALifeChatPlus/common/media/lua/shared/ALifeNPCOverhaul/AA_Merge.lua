-- A-Life Chat Plus + A-Life Talk, merged.
-- A-Life Talk does free chat, relationships, notes, grief, radio, ambient life and backstories.
-- Chat Plus keeps what A-Life Talk doesn't have (driving, pickups, signs, prisoners, haggling, setup/status, chat fix)
-- and switches its own overlapping parts off so two AIs never answer the same line.
ALifeMerge = ALifeMerge or {}
ALifeMerge.on = true
ALifeMerge.off = {
    respond = true,     -- ALifeChatAI's Talk.respond hook (A-Life Talk answers instead); the bridge client stays
    radio = true,       -- walkie/whisper/yell hook (A-Life Talk has its own radio)
    notes = true,       -- paper notes (A-Life Talk has notes); territory signs stay
    bodies = true,      -- grief at bodies (A-Life Talk grieves)
    ambient = true,     -- NPC chatter (A-Life Talk ambient)
    radioTraffic = true,-- radio chatter (A-Life Talk news)
    household = true,   -- resident friendships (A-Life Talk social/pairs)
    immersion = true,   -- extra personal questions (A-Life Talk's AI answers them)
    story = true,       -- AI backstories (A-Life Talk has personalities and backstories)
}
function ALifeMerge.skip(name) return ALifeMerge.on == true and ALifeMerge.off[name] == true end
print("[ALifeNPCOverhaul] merged with A-Life Talk: overlapping Chat Plus parts are off")
