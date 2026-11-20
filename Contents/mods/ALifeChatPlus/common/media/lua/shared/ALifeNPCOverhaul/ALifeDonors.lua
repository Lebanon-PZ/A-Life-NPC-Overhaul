-- A-Life NPC Overhaul 0.7.12: SUPPORTERS. People who back the mod show up in it (ALifeStrangers does the showing).
-- Edit the LIST below; nothing else needs changing. A donor is only used when "approved = true".
--
-- Tiers (what each one gets in game):
--   3   Discord donor role only: nothing in game (listed here so the credits stay in one place, credit = false).
--   5   Named cameo: someone in the world carries their name (the first fitting stranger you meet after day 2).
--   15  Cameo plus their pick of what that person is: kind = "trader", "guard", "medic", "leader", "loner",
--       "soldier" or "oddball" (with oddball, set oddball = one of ALifeStrangers.ODDBALL ids, e.g. "santa").
--   30  Everything above plus one short custom line, said where they chose: lineAt = "radio" (heard once on the
--       radio, as their character) or "note" (written on a note their character leaves somewhere you'll pass).
--       The line must be approved before shipping: keep it short, no real-world names, nothing that breaks the world.
--   50  Rare cameo treatment and a credits mention: they appear in every world (not by chance), in person, with a
--       short description of who they are (persona, approved), and they're thanked in Help > Thanks.
--
-- Fields: name (as shown in game, "First Last" or "First"), sex ("m"/"f"/nil = any), tier, kind, oddball, line,
--         lineAt, persona (tier 50: one or two sentences about who they are), approved, credit (show in Help > Thanks).

ALifeDonors = ALifeDonors or {}
local D = ALifeDonors

D.LIST = {
    -- the $50 supporter: fill in name / sex / kind / persona / line, then set approved = true
    { id = "donor50_1", name = "", sex = nil, tier = 50, kind = "loner", oddball = nil,
      persona = "", line = "", lineAt = "radio", approved = false, credit = true },
}

-- only rows that are filled in and approved
function D.active()
    local out = {}
    for _, d in ipairs(D.LIST) do
        if type(d) == "table" and d.approved == true and type(d.name) == "string" and d.name ~= "" then out[#out + 1] = d end
    end
    return out
end
-- Help > Thanks
function D.creditsText()
    local names = {}
    for _, d in ipairs(D.LIST) do
        if type(d) == "table" and d.approved == true and d.credit == true and type(d.name) == "string" and d.name ~= "" then
            names[#names + 1] = d.name
        end
    end
    if #names == 0 then return nil end
    return "Thanks to the people who keep this mod going: " .. table.concat(names, ", ") .. ". Some of them may cross your path."
end
print("[ALifeDonors] loaded: " .. #D.active() .. " supporters in game")
