-- A-Life NPC Overhaul pre-1.0 (MP port P6, docs/PLAN-MP.md): THE WINDOWS ON AN MP CLIENT.
-- The people book, the talk window, the relationship (Bond) panel, the party and places windows call ALifeLLMTalk
-- functions that read A-Life's world (who someone is, how they feel, what you did together). On an MP client that
-- world is on the server, so:
--   * READS (R.readable): the window gets the server's answer for that person, asked in the background; it shows on
--     the window's next refresh (a blank line until then). Only the names below cross; arguments are plain values
--     (a uid, a number); "you" is always the sender.
--   * BUTTONS (R.expose): the Bond panel's choices run on the server as the one who clicked; the person answers out
--     loud (A-Life's speech reaches everyone near), the panel refreshes from the reads.
-- Single player / the server: nothing changes (no wrapping there).
require "ALifeNPCOverhaul/AA_Side"
require "ALifeNPCOverhaul/ALifeRemote"
if type(ALifeRemote) ~= "table" or type(ALifeRemote.readable) ~= "function" then return end
local R = ALifeRemote
ALifeRemoteUI = ALifeRemoteUI or {}
local U = ALifeRemoteUI
U.VERSION = ALifeSide.MOD_VERSION
-- name = { nArgs, playerAt } (playerAt = where the server puts the sender; past nArgs = not passed)
U.READS = {
    -- a person, by uid
    activityLine = { 1 }, ageOf = { 1 }, bookAwayText = { 1 }, bondTier = { 1 }, changeWord = { 1 }, grudgeOf = { 1 },
    histRows = { 1 }, isPaused = { 1 }, likesShown = { 1 }, loveLine = { 1 }, nemesisOf = { 1 }, profileOf = { 1 },
    promisesOf = { 1 }, romanceOf = { 1 }, thoughtOf = { 1 }, togetherView = { 1 }, traitLines = { 1 },
    interactionsOf = { 1 }, learnedStory = { 1 }, keyMemOf = { 1 }, biteInfo = { 1 }, drunkOf = { 1 }, lastSeenTag = { 1 },
    partnerWord = { 1 }, personaMods = { 1 }, lens = { 1 }, isFinalDead = { 1 }, settlerAway = { 1 }, personaKind = { 1 },
    moodOf = { 2 }, traitChart = { 2 },
    -- a person, and the uid's record looked up on the server (the client's record argument is not sent)
    lastSeenOf = { 1 }, personaOf = { 1 }, isPersonDead = { 1 }, woundState = { 1 },
    -- a person and YOU (the sender)
    bondAskState = { 1, 2 }, bondStanding = { 1, 2 }, shownName = { 1, 2 }, baseWhere = { 1, 2 }, baseAskState = { 1, 2 },
    tiesOf = { 3, 2 }, closeWithLine = { 1, 2 },
    -- the people book's list: everyone you know (rows: uid, name, how they feel about you, dead / away)
    knownNpcs = { 0, 1 },
}
U.BUTTONS = {
    bondDecide = { 2, 3 }, bondApologize = { 1, 2 }, bondStepBack = { 1, 2 }, romanceAsk = { 1, 2 }, baseButton = { 1, 2 },
}
-- these return a list / table: {} until the server answers (the windows walk them)
U.LISTS = { knownNpcs = true, histRows = true, promisesOf = true, interactionsOf = true, keyMemOf = true, tiesOf = true,
    traitLines = true, traitChart = true, personaMods = true, lens = true,
    -- tables the windows index straight away (st.ask, s.hurt): {} until the server answers, never nil
    woundState = true, bondAskState = true, baseAskState = true }
for name, s in pairs(U.READS) do R.readable(name, s[1], s[2], U.LISTS[name] == true) end
for name, s in pairs(U.BUTTONS) do R.expose(name, s[1], s[2]) end
print("[ALifeRemoteUI] ready " .. U.VERSION .. ": windows read the server's world on an MP client")
return U
