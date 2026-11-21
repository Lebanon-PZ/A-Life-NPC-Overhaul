# A-Life NPC Overhaul: Relationships, Factions & Building

Project Zomboid Build 42 (42.21) add-on for [Project A-Life NPCs](https://steamcommunity.com/sharedfiles/filedetails/?id=3803984183).

- Mod ID: `ALifeChatPlus`
- Steam Workshop ID: 3827364142
- Author: Lebanon

Licensed: personal modification OK; to share changes, make a companion mod. See LICENSE.

Adds relationships, factions, camp life and NPC building on top of Project A-Life NPCs.
An optional AI bridge (local Ollama / LM Studio, or an OpenAI-compatible API with your own key) lives in `Contents/mods/ALifeChatPlus/bridge/`. The mod works fine with AI off.

## Install

Subscribe on the Steam Workshop. Do not copy into `Zomboid/mods`.

## Code layout

All Lua is in `Contents/mods/ALifeChatPlus/common/media/lua/`. Every file name is unique; the folders are namespaces, not copies.

| Folder | What it owns |
|---|---|
| `shared/ALifeNPCOverhaul/` | World systems: bonds, factions, orders, prisoners, caravans, building, quests, legacy. `AA_*` files are the shared helpers every module uses (`AA_Side` = which side runs what in MP, `AA_Health` = error guard + health log, `AA_Move` = safe NPC moves, `AA_Tick`, `AA_Tr`, ...). |
| `shared/ALifeLLMTalk/` | Talking, camp life and the A-Life window logic. `ALifeLLMTalk_*` = the talk core (prompts, memory, AI relay, personalities); `ALifeTalk_*` = features built on it. The folder name is historic (the mod started as "A-Life LLM Talk"). |
| `shared/ALifeTalkPatch/` | One file: in-memory patches to Project A-Life's own talk/relations functions. Nothing on disk is edited. |
| `client/` | UI only (window pages, radial, popups). No world logic. |
| `server/` | Dedicated-server-only code. |
| `shared/Translate/` | Text (EN). |

Multiplayer: world logic lives in `shared/` and runs only where `ALifeSide.world()` is true (single player, or the server). UI runs only where `ALifeSide.ui()` is true. Every file declares its side once with `ALifeSide.hooks(...)`, or guards its handlers with `ALifeSide.world()` / `ALifeSide.ui()`. Client and server talk over one command channel, `ALifeCmd`.

`ALifeLLMTalk_PersonaData.lua` is generated data (personality library, 4556 entries) and is not edited by hand.

AI bridge (optional): `bridge/`. `alifetalk_bridge.py` is the HTTP relay to the model; `alifetalk_memory.py`, `alifetalk_prompts.py` and `alifetalk_report.py` hold memory, prompts and diagnostics. The `.ps1`/`.cmd` files start, stop, set up and uninstall it.
