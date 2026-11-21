#!/usr/bin/env python3
"""
A-Life Talk bridge (version: see VERSION below): connects the ALifeTalk Project Zomboid add-on to a local Ollama model.

The game writes   <Zomboid>/Lua/alifetalk_request.json
This script writes <Zomboid>/Lua/alifetalk_reply.txt   (+ heartbeat alifetalk_status.txt)

Standard library only, Python 3.8+.
  python alifetalk_bridge.py [--model llama3.2:3b] [--dir C:\\Users\\you\\Zomboid\\Lua]
                             [--ollama http://127.0.0.1:11434] [--background-model NAME] [--timing] [--echo] [--num-predict 80] [--num-ctx 4096]
Env vars: ALIFETALK_MODEL, ALIFETALK_DIR, OLLAMA_HOST
"""
import argparse
import difflib
import json
import os
import re
import socket
import sys
import threading
import time
import http.client
import urllib.error
import urllib.parse
import urllib.request

sys.dont_write_bytecode = True  # pre-1.0: no __pycache__ in the mod folder (it would ship with the next upload)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from alifetalk_memory import Memory, SUMMARY_SCHEMA, Embedder  # noqa: E402
import alifetalk_prompts as PROMPTS  # noqa: E402  0.8.12: prompt text + AI rules from prompts.txt / alifeai_prompts.txt, live
try:
    from alifetalk_report import Reporter  # noqa: E402  (0.6.20: optional bug reports, off by default)
except Exception:  # noqa: BLE001
    Reporter = None

VERSION = "0.8.11.2"  # 0.8.11.2: fail replies carry why=, fight info (zombies, youHelp, trust)
PLAYER_MODES = ("reply", "radio", "gift")
REQ = "alifetalk_request.json"
REPLY = "alifetalk_reply.txt"
STATUS = "alifetalk_status.txt"
DEFAULT_MODEL = "llama3.1:8b"

TONES = ["NONE", "GREETING", "FAREWELL", "THANKS", "SORRY", "COMPLIMENT", "I_AM_FRIENDLY", "OFFER_HELP",
         "INSULT", "THREATEN", "GO_AWAY"]

STANCE = {
    "friendly": "You are on good terms with them.",
    "neutral": "You don't know them yet; polite, a little wary, but you can still chat and joke.",
    "careful": "You are wary of them right now; guarded, short answers.",
    "hostile": "You consider them an enemy.",
}


def log(*a):
    print(time.strftime("[%H:%M:%S]"), *a, flush=True)


def default_dir():
    env = os.environ.get("ALIFETALK_DIR")
    if env:
        return env
    home = os.environ.get("USERPROFILE") or os.path.expanduser("~")
    return os.path.join(home, "Zomboid", "Lua")


# 0.8.2 part 2: THE AI PICKS THE COMMAND. When the player talks to one of their own people and no command words
# matched, the mod sends req.cmds = [{id, label, item}]; the model sets cmd (and cmdItem for gear) ONLY when this
# line asks them to do one of those AND they agree. The mod then carries it out with A-Life's own orders.
def command_rule(req):
    if req.get("mode") not in (None, "", "reply"):
        return None
    cmds = [c for c in _lst(req.get("cmds")) if isinstance(c, dict) and _s(c.get("id"), 30)]
    if not cmds:
        return None
    lst = "; ".join(f"{_s(c.get('id'), 30)} = {_s(c.get('label'), 40)}" for c in cmds[:40])
    return ("They may ask or tell you to do things. Things you could do for them: " + lst + ". "
            "cmd = the id ONLY if their line asks you to do one of these and you agree (your line says yes in your own "
            "words); otherwise NONE. If you refuse, cmd NONE and say why. cmdItem = the thing named, for hand it over / "
            "carry this.")


def clean_cmd(req, raw):
    ids = {_s(c.get("id"), 30) for c in _lst(req.get("cmds")) if isinstance(c, dict)}
    v = _s(raw, 30)
    return v if v in ids else ""


# 0.8.5: STAND-OFFS. req.standoff = {"said": the player's words, "kinds": [{id, label}]}: the model answers in its
# own voice (react "what") AND sets sokind = the id of what the player's words meant (A-Life's answer kinds), or NONE.
def standoff_rule(req):
    if req.get("mode") != "standoff":
        return None
    so = req.get("standoff")
    if not isinstance(so, dict):
        return None
    kinds = [k for k in _lst(so.get("kinds")) if isinstance(k, dict) and _s(k.get("id"), 20)]
    if not kinds or not _s(so.get("said"), 200):
        return None
    lst = "; ".join(f"{_s(k.get('id'), 20)} = {_s(k.get('label'), 60)}" for k in kinds[:12])
    return ("They just answered you: '" + _s(so.get("said"), 200) + "'. JSON sokind = what their words MEAN, one of: "
            + lst + "; NONE if it's none of these. Judge the meaning, not the exact words ('it's only me' = alone, "
            "'here, have my stuff' = pay).")


def clean_sokind(req, raw):
    so = req.get("standoff") if isinstance(req.get("standoff"), dict) else {}
    ids = {_s(k.get("id"), 20).lower() for k in _lst(so.get("kinds")) if isinstance(k, dict)}
    v = _s(raw, 20).lower()
    return v if v in ids else ""


# 0.8.3 step 10: ASKS BECOME THINGS. req.wants = {"can": [kinds], "open": {"kind", "ago"}}: the model sets want to the
# thing THEY ask the player for in this line (food / water / medicine / ammo); the mod remembers it and notices when the
# player brings it. open = what they already asked for and are still waiting on.
WANTS = ["food", "water", "medicine", "ammo"]


def want_rule(req):
    if req.get("mode") not in (None, "", "reply"):
        return None
    w = req.get("wants")
    if not isinstance(w, dict):
        return None
    kinds = [k for k in _lst(w.get("can")) if k in WANTS]
    t = ""
    if kinds:
        t = ("If your line asks them to bring or give you something you really need, want = what it is ("
             + ", ".join(kinds) + "); otherwise NONE. Only ask for what you'd really need; never demand.")
    o = w.get("open")
    if isinstance(o, dict) and _s(o.get("kind")) in WANTS:
        t += (f" You asked them for {_s(o.get('kind'))} {_s(o.get('ago'), 30) or 'earlier'} and they haven't brought it yet;"
              " you may mention it if it fits.")
    return t.strip() or None


def clean_want(req, raw):
    v = _s(raw, 20).lower()
    w = req.get("wants") if isinstance(req.get("wants"), dict) else {}
    kinds = [k for k in _lst(w.get("can")) if k in WANTS]
    return v if v in kinds else ""


# 0.8.3 step 7: BODY LANGUAGE. A-Life 1.5's TalkGesture moods (ALifeTalkGestureRows.lua); the mod plays the
# gesture plan A-Life has for that mood (it still decides how often a line gets one).
GESTURES = ["neutral", "friendly", "emphatic", "question", "nervous", "angry"]


def gesture_rule(req):
    if req.get("mode") not in (None, "", "reply") or not req.get("gestures"):
        return None
    return ("gesture = how you carry your line with your body: neutral, friendly (warm, open), emphatic (making a point), "
            "question (asking, puzzled), nervous (scared, unsure, hiding something) or angry.")


def schema(acts):
    return {
        "type": "object",
        "properties": {
            "tone": {"type": "string", "enum": TONES},
            "act": {"type": "string", "enum": ["NONE"] + [a for a in acts if isinstance(a, str)]},
            "d": {"type": "integer", "minimum": -10, "maximum": 10},
            "leave": {"type": "boolean"},
            "say": {"type": "string"},
            "suggest": {"type": "array", "items": {"type": "string"}, "maxItems": 3},  # 0.8.3 step 3 (optional)
            "ask": {"type": "boolean"},  # 0.8.3 step 4 (optional): your line asks them something you want answered
            "gesture": {"type": "string", "enum": GESTURES},  # 0.8.3 step 7 (optional): A-Life TalkGesture mood
            "cmd": {"type": "string"},  # 0.8.2 part 2 (optional): the command they agree to do (from req.cmds)
            "cmdItem": {"type": "string"},  # 0.8.2 part 2 (optional): the thing, for gear commands
            "want": {"type": "string", "enum": ["NONE"] + WANTS},  # 0.8.3 step 10 (optional): what they ask you for
            "sokind": {"type": "string"},  # 0.8.5 (optional): which stand-off answer the player's words meant
        },
        "required": ["tone", "act", "d", "leave", "say"],
    }


def _s(v, n=80):
    return re.sub(r"\s+", " ", str(v or "")).strip()[:n]


DRUNK_STYLE = [
    "a little looser and friendlier than usual.",
    "looser, chattier and funnier; you say what you think a bit more honestly.",
    "loud, blunt and honest, laugh easily, ramble a little, wording a bit sloppy (\"y'know\", trailing off).",
    "slurring and sloppy (stretched or doubled letters now and then), overly honest, emotional, easily sidetracked.",
]


def person_line(p, label):
    if not p:
        return ""
    bits = [_s(p.get("name"), 40) or "someone"]
    role = _s(p.get("role"), 40)
    if role:
        bits.append(role)
    manner = ", ".join(x for x in (_s(p.get("temper"), 20), _s(p.get("register"), 20)) if x)
    if manner:
        bits.append("manner " + manner)
    if p.get("mood"):
        bits.append("mood " + _s(p.get("mood"), 20))
    if p.get("activity"):
        bits.append("doing " + _s(str(p.get("activity")).replace("_", " "), 30))
    if p.get("drunkLabel"):
        bits.append(_s(p.get("drunkLabel"), 20))
    rel = {"friendly": "you get on well", "neutral": "you're neutral", "hostile": "bad blood between you"}.get(p.get("toward"))
    if p.get("sameGroup"):
        rel = (rel + ", " if rel else "") + "same group"
    elif p.get("sameSide"):
        rel = (rel + ", " if rel else "") + "same side"
    return f"{label}: " + "; ".join(bits) + (f" ({rel})" if rel else "") + "."


def gift_text(req):
    g = req.get("gift") or {}
    items = [i for i in (g.get("items") or []) if isinstance(i, dict)]
    parts = []
    for i in items[:4]:
        bits = [_s(i.get("kind"), 12)]
        if i.get("alcohol") and i.get("kind") != "alcohol":
            bits.append("alcohol")
        if i.get("rotten"):
            bits.append("rotten")
        if isinstance(i.get("value"), (int, float)) and i["value"] > 0:
            bits.append(f"worth {int(i['value'])}/100")
        parts.append(f"{_s(i.get('name'), 50)} ({', '.join(b for b in bits if b)})")
    what = "; ".join(parts) or "something"
    if g.get("trade"):
        got = ", ".join(_s(x, 40) for x in (g.get("received") or []) if x)
        return f"[Trade: they hand you {what}" + (f" and take your {got}" if got else "") + "]"
    return f"[They hand you {what}]"


REACT_MODES = ("sound", "grief", "injury", "injury_self", "taunt", "news", "follow", "calm", "warn", "nemesis", "promise", "betray",
               "world", "quest", "order",
               # v0.5.1
               "last_words", "activity", "wound_talk", "dream", "weather", "letter", "love", "weird", "reputation", "settle",
               "outfit", "party",
               # v0.5.1.7
               "bond", "grudge", "habit", "thought",
               # v0.5.1.8
               "baseParty",
               # v0.5.2
               "npcBase",
               # 0.8.3 step 8: they walk up to you with something to say
               "approach",
               # 0.8.5: stand-off lines in their own voice (A-Life's order and meaning); sokind reads the player's answer
               "standoff")
# v0.5.1: lines that are written, never spoken or voiced (0.5.1.7: "thought" = what they think of you, shown in the Bond tab)
WRITTEN_MODES = ("letter", "thought")
CHATTER_MODES = ("ambient", "chime", "banter")
# v0.5.1: filler that made NPCs sound like greeting cards; a line containing one is retried once
FILLER = re.compile(r"\b(stay safe( out there)?|be careful out there|take care of yourself out there|we('| a)re all in this together|"
                    r"one day at a time|it is what it is|hang in there|keep your head down|watch your back out there|"
                    r"these are (tough|dark|hard) times|in times like these|the world (has|'s) gone (to hell|crazy|mad))\b", re.I)
# v0.5.0: these moments always get a line (no "stay quiet" escape; retry once, then a stock line in their style).
# 0.4.2 logged many "(stays quiet)" for taunts and own injuries because the prompt allowed say "".
MUST_SPEAK = ("taunt", "injury_self", "nemesis", "betray", "warn", "promise", "quest", "order", "standoff")
MUST_LINES = {
    "taunt": ["You're done!", "Come here!", "That all you got?", "You picked the wrong fight.", "I'll bury you!",
              "Run while you can.", "Nobody's coming for you."],
    "injury_self": ["Agh - I'm hit!", "Damn it, that hurts!", "I'm bleeding here!", "Ow - son of a...", "I'm hurt, I'm hurt!",
                    "Ugh... that's bad."],
    "nemesis": ["Remember me?", "Told you I'd find you.", "Thought you got rid of me?", "This time you don't walk away."],
    "betray": ["I'm done with you.", "You had this coming.", "Sorry. Not sorry.", "Should've watched your back."],
    "warn": ["Back off. Last warning.", "Don't push me.", "Walk away. Now.", "I won't say it again."],
    "promise": ["You'd better mean that.", "I'll hold you to it.", "Don't make me regret trusting you."],
    "quest": ["Thanks. I owe you.", "You came through.", "Good. That helps a lot."],
    "order": ["Got it.", "On it.", "Yeah, yeah, going.", "Fine.", "Copy that."],
    "standoff": ["Easy. Nobody move.", "Stay right there.", "Talk. Now.", "Don't try anything."],
}
MUST_LINES_DARK = {
    "taunt": ["Hah. You'll die tired.", "Nobody'll miss you.", "Pathetic."],
    "injury_self": ["Figures. Course it does.", "Great. Just great.", "...doesn't even matter."],
    "order": ["Whatever.", "Sure, boss. Whatever you say.", "Fine. Happy now?"],
}


FIGHT_TRUST = {"trusts": "you trust the newcomer", "warming": "you're warming to the newcomer",
               "stranger": "the newcomer is a stranger to you", "distrusts": "you don't trust the newcomer"}


def fight_vs_dead(req):
    """0.8.11.2 (Miller): busy fighting the dead, not hostile to the newcomer."""
    fight = req.get("fight") or {}
    return bool(fight.get("fighting")) and not fight.get("hostile")


def context_v32(req, npc):
    """v3.2 context: sounds, relationships, grief, fight state, trip. Each block is skipped when empty (token-cheap)."""
    out = []
    snd = [x for x in (req.get("sounds") or []) if isinstance(x, list) and len(x) >= 1]
    if snd:
        def ago(sec):
            sec = int(sec or 0)
            return "just now" if sec < 15 else f"{sec}s ago" if sec < 60 else f"{sec // 60} min ago"
        out.append("Sounds you heard (oldest first): " + "; ".join(
            f"{_s(x[0], 40)} ({ago(x[1] if len(x) > 1 else 0)}{', ' + _s(x[2], 20) if len(x) > 2 and x[2] else ''})"
            for x in snd[:6]) + ".")
    prs = [x for x in (req.get("pairs") or []) if isinstance(x, list) and len(x) >= 3]
    if prs:
        def pr(x):
            sc = int(x[2] or 0)
            bit = f"{_s(x[0], 30)} - your {_s(x[1], 40)} ({sc:+d}"
            if len(x) > 3 and x[3]:
                bit += ", dead"
            if len(x) > 4 and x[4]:
                bit += "; " + _s(x[4], 40)
            return bit + ")"
        out.append("Your people (bond -100..100): " + "; ".join(pr(x) for x in prs[:6]) + ".")
    if req.get("youTie") and req.get("mode") not in ("ambient",):
        out.append(f"What the newcomer is to you: {_s(req['youTie'], 30)}.")
    if req.get("pairType"):
        out.append(f"{_s((req.get('partner') or {}).get('name'), 30) or 'They'} is your {_s(req['pairType'], 40)}"
                   + (f" (bond {int(req.get('pairScore') or 0):+d})" if isinstance(req.get("pairScore"), (int, float)) else "") + ".")
    grief = [x for x in (req.get("grief") or []) if isinstance(x, list) and len(x) >= 7]
    drunk = npc.get("drunk") if isinstance(npc.get("drunk"), (int, float)) else 0
    for g in grief[:2]:
        name, word, ago, killer, saw, mood, inten = g[:7]
        anniv = g[7] if len(g) > 7 else 0
        src = g[8] if len(g) > 8 else ""
        fresh = g[9] if len(g) > 9 else 0
        how = "killed by the newcomer talking to you" if killer == "player" else (
            "killed by zombies" if killer in ("zombies", "zombie", "a zombie") else f"killed by {_s(killer, 30)}" if killer and killer != "?" else "died")
        line = (f"GRIEF: {_s(name, 30)}, your {_s(word, 30)}, {how} {_s(ago, 20)}"
                + (" - you saw it" if saw else (f" - {_s(src, 40)}" if src else "")) + f". You feel {_s(mood, 50)}")
        line += " (it still weighs on you heavily)" if inten >= 50 else " (it comes back now and then)" if inten >= 20 else ""
        if anniv:
            line += f"; it's been {int(anniv)} days today"
        line += "."
        if fresh and req.get("mode") in (None, "", "reply", "radio", "news"):
            line += " You JUST found out - this hits you first, whatever else is said."
        if drunk >= 30 and inten >= 15:
            line += " The drink brings it up: you get emotional about it."
        out.append(line)
    if grief:
        out.append("Grief colors how you talk; mention them only when it fits (a name, a memory), not every line.")
    if req.get("news"):
        n = req["news"]
        out.append(f"You must tell {_s((req.get('partner') or {}).get('name'), 30) or 'them'} that {_s(n[0], 30)} is dead"
                   + (f" ({_s(n[1], 30)})" if len(n) > 1 and n[1] and n[1] != "something" else "") + "; they don't know yet. Say it now, in your own way.")
    elif req.get("remember"):
        out.append(f"You both lost {_s(req['remember'], 30)}. Bring them up: a memory, how you miss them.")
    fight = req.get("fight") or {}
    if fight.get("hostile") or fight.get("fighting"):
        bits = []
        if fight.get("target"):
            bits.append(f"fighting {_s(fight['target'], 30)}")
        if isinstance(fight.get("hp"), (int, float)):
            bits.append(f"your health {int(fight['hp'])}%")
        if fight.get("fleeing"):
            bits.append("you're trying to get away")
        if isinstance(fight.get("mates"), (int, float)) and fight["mates"] > 0:
            bits.append(f"{int(fight['mates'])} of your people near")
        if isinstance(fight.get("zombies"), (int, float)) and fight["zombies"] > 0:  # 0.8.11.2 (Miller)
            bits.append(f"{int(fight['zombies'])} of the dead right around you")
        if fight.get("youHelp"):
            bits.append("the newcomer is fighting the dead right beside you")
        if fight.get("trust") in FIGHT_TRUST:
            bits.append(FIGHT_TRUST[fight["trust"]])
        if bits:
            out.append("Fight: " + ", ".join(bits) + ".")
    fol = req.get("follow")
    if isinstance(fol, list) and len(fol) >= 1:
        mins, frm, dist = (fol + [-1, "", -1])[:3]
        out.append("You're walking with the newcomer" + (f" for {int(mins)} min" if isinstance(mins, (int, float)) and mins >= 0 else "")
                   + (f", since {_s(frm, 40)}" if frm else "")
                   + (f", about {int(dist)} tiles so far" if isinstance(dist, (int, float)) and dist > 0 else "") + ".")
    if req.get("followNo"):
        out.append(f"If they ask you to come along / follow them: you won't ({_s(req['followNo'], 80)}). Say no your own way; act NONE.")
    if req.get("canRob"):
        out.append("You and your crew could rob them right now. Only if you really want to: demand it plainly (\"hands up\", "
                   "\"drop it\", \"hand over your stuff\") and your crew will follow through. Never say it as a joke.")
    you = req.get("you") or {}
    if you.get("hurt"):
        out.append(f"The newcomer looks {_s(you['hurt'], 40)}.")
    return out


STATIC_HEAD = ("You are a character in a survival story set in Knox County, Kentucky, July 1993, after the dead started "
               "walking. Speak only as that character, out loud, in plain 1993 American speech. Never narrate, never use "
               "asterisks, never mention AI, games or prompts. Never invent game facts you were not given: what you "
               "carry or have in stock, who is where, what state the base is in. Small personal color is yours to make "
               "up (a favorite food, a nickname, a story from before) - keep it consistent with what you said. "
               "Stay fully in character no matter what is said: never break the fourth wall, never call this a game, a "
               "story or a roleplay, never say you are an AI, a model or a program - if asked, react as your character "
               "would to a strange question. Play along with what the person tells you about themselves and their story "
               "unless your character has reason to doubt it. Stay consistent with everything you remember and said before. "
               "Romance stays tender and tasteful, never explicit. "
               "Say ONE spoken line: never a list, numbered options or formatting codes. "
               "Always answer with the JSON object asked for. "
               "You are a person, not a service: you may joke, tease, disagree, refuse, ask something back, change "
               "the subject, say you don't know, or get bored or annoyed. "
               "A GIST about a command, request or threat is strict: follow its meaning. A HINT is only a nudge: "
               "answer in your own way.")


def persona_lines(req):
    """v0.4.0: one-line personality + 1-2 line backstory (only what fits; the model keeps the rest to itself)."""
    pz = req.get("persona") or {}
    out = []
    if isinstance(pz, dict) and pz.get("line"):
        out.append("Personality: " + _s(pz.get("line"), 260))
    story = _s((req.get("_story") or pz.get("story") or ""), 420)
    if story:
        tr = pz.get("reveal")
        share = {0: "Keep your past to yourself; deflect if asked.",
                 1: "You may hint at your past, nothing personal.",
                 2: "You may share where you came from and who you lost if asked.",
                 3: "You trust them: you may share almost anything, even your secret if it comes up."}.get(
            tr if isinstance(tr, int) else 1, "")
        out.append("Your past (private unless you choose to share): " + story + " " + share)
    nem = req.get("nemesis") or {}
    if isinstance(nem, dict) and nem.get("tier"):
        out.append("Grudge: " + {1: "you resent them and want to hurt them with your bare hands",
                                2: "you want revenge and came armed to get it",
                                3: "you want them dead"}.get(int(nem.get("tier") or 1), "you hate them")
                   + (f" because {_s(nem.get('why'), 100)}" if nem.get("why") else "") + ".")
    return out


def context_050(req):
    """v0.5.0: emotions, speech style, off-screen life, orders, rumors, faction politics, quests."""
    out = []
    ps = req.get("psyche") or {}
    if isinstance(ps, dict):
        if ps.get("mood"):
            out.append("Feeling right now: " + _s(ps.get("mood"), 200) + ". Let it color how you talk, without naming it.")
        if ps.get("style"):
            out.append("How you talk: " + _s(ps.get("style"), 260) + ".")
        if ps.get("kind") == "dark":
            out.append("You are a difficult person: you may insult, mock, sneer, sulk or refuse - but you are NOT hostile "
                       "and you don't start fights just because of your temper.")
        elif ps.get("kind") == "unhinged":
            out.append("Your mind isn't right: odd leaps, things only you believe, sudden shifts - unsettling but not "
                       "violent unless someone attacks you. Keep it human and coherent enough to follow.")
        if ps.get("life"):
            out.append("Lately: " + _s(ps.get("life"), 260) + ".")
    od = req.get("order") or {}
    if isinstance(od, dict) and od.get("kind"):
        out.append(f"The newcomer just ordered you to {_s(od.get('kind'), 30).replace('_', ' ')}. "
                   + ("You do it - acknowledge in your own words." if od.get("obeyed")
                      else "You won't - refuse or argue in your own words."))
    so = req.get("social") or {}
    if isinstance(so, dict):
        rum = [r for r in (so.get("rumors") or []) if isinstance(r, list) and r]
        if rum:
            out.append("Things you've heard about the newcomer: " + "; ".join(
                f"{_s(r[0], 120)} ({_s(r[1], 40)})" if len(r) > 1 else _s(r[0], 120) for r in rum[:2])
                + ". You may bring it up if it fits; hearsay may be wrong.")
        if so.get("politics"):
            out.append("Your faction's situation: " + _s(so.get("politics"), 240))
    q = req.get("quest") or {}
    if isinstance(q, dict):
        rw = f" Reward you offer: {_s(q.get('reward'), 40)}." if q.get("reward") else ""
        if q.get("offer"):
            out.append(f"They're asking if you have work for them. You do: ask them to {_s(q['offer'], 140)}.{rw} "
                       "Offer it in your own words (one or two short sentences) and ask if they're in.")
        elif q.get("accepted"):
            out.append(f"They just agreed to do your job ({_s(q['accepted'], 120)}). React briefly in character.{rw}")
        elif q.get("declined"):
            out.append(f"They turned down your job ({_s(q['declined'], 100)}). React briefly in character.")
        elif q.get("refuse"):
            out.append(f"They're asking for work. You have none for them: {_s(q['refuse'], 100)}.")
        elif q.get("active"):
            out.append(f"They are doing a job for you: {_s(q['active'], 120)}"
                       + (f" ({_s(q.get('progress'), 60)})" if q.get("progress") else "") + ". You may ask how it's going.")
    return out


def context_051(req):
    """v0.5.1: the NPC's own body (exact wounds) and how their bonds changed lately."""
    out = []
    w = req.get("wounds") or {}
    if isinstance(w, dict) and (w.get("list") or w.get("treated")):
        items = [_s(x, 110) for x in (w.get("list") or []) if isinstance(x, str)]
        if items:
            more = f" (+{int(w['more'])} smaller ones)" if isinstance(w.get("more"), (int, float)) and w["more"] else ""
            body = "Your body right now: " + "; ".join(items) + more + "."
            eff = []
            if w.get("limp"):
                eff.append("you limp and can't run")
            if w.get("arm"):
                eff.append("one arm is weak - aiming and swinging hurt")
            if w.get("downed"):
                eff.append("you're down on the ground, bleeding out")
            if isinstance(w.get("hp"), (int, float)) and w["hp"] < 50:
                eff.append("you feel weak and lightheaded")
            if isinstance(w.get("pain"), (int, float)) and w["pain"] >= 6:
                eff.append("the pain is bad")
            if eff:
                body += " " + "; ".join(eff).capitalize() + "."
            out.append(body + " If asked how you are or if you're okay, answer about THESE exact injuries in your own "
                       "way (which part, how it feels, what you can't do); don't invent other injuries.")
            if w.get("bitten"):
                out.append("You were bitten. You know what bites usually mean - you may hide it, deny it or fear it.")
        if w.get("wantsBandage"):
            out.append("You need a bandage or clean rags for the bleeding; you may ask the newcomer for one.")
        if w.get("treated"):
            out.append(_s(w["treated"], 160).capitalize() + ". Thank them in your own way, briefly.")
    bn = [b for b in (req.get("bondNews") or []) if isinstance(b, str)]
    if bn:
        out.append("Lately between you: " + "; ".join(_s(b, 120) for b in bn[:2]) + ". It may color what you say.")
    return out


PAIR_POS = {"JOKE": ("haha", "heh", "joke", "kidding", "funny", "laugh", "remember when", "you crack me up"),
            "SUPPORT": ("you okay", "got your back", "we'll make it", "i'm here", "thank you", "thanks", "proud of you",
                        "you did good", "good job", "don't worry", "take care", "glad you're", "love you", "need a hand"),
            "FRIENDLY": ("buddy", "pal", "friend", "good to see", "nice", "how you holding", "how are you", "sure thing")}
PAIR_NEG = {"THREAT": ("i'll kill you", "i'll hurt you", "watch your back", "or else", "i'll end you", "you're dead"),
            "INSULT": ("idiot", "moron", "stupid", "useless", "pathetic", "worthless", "dumbass", "loser", "freak", "shut up",
                       "screw you", "hate you", "piece of"),
            "MOCK": ("nice going", "real smart", "genius", "oh great", "big man", "tough guy", "coward", "crybaby"),
            "ARGUE": ("you're wrong", "that's not", "no way", "bull", "that's crap", "whatever", "don't tell me", "says who",
                      "your fault", "back off")}
PAIR_JSON = ("JSON: act NONE, leave false; tone = how your line treats them: COMPLIMENT or I_AM_FRIENDLY (warm, joking, supportive), OFFER_HELP, INSULT (mocking, insulting, arguing), THREATEN, or NONE; d = -5..5, how much the line warms (+) or sours (-) things between you two.")
PAIR_DELTA = {"JOKE": 2, "SUPPORT": 3, "FRIENDLY": 1, "NEUTRAL": 0, "ARGUE": -2, "MOCK": -3, "INSULT": -4, "THREAT": -6}


def pair_tag(text, tone="NONE", d=0):
    """v0.5.1: how an NPC-NPC line treats the other one -> (tag, delta). Model tone first, keyword fallback."""
    low = " " + (text or "").lower() + " "
    if not low.strip():
        return "NEUTRAL", 0
    for tag, words in PAIR_NEG.items():
        if any(w in low for w in words):
            return tag, PAIR_DELTA[tag]
    if tone == "THREATEN":
        return "THREAT", PAIR_DELTA["THREAT"]
    if tone in ("INSULT", "GO_AWAY"):
        return "INSULT", min(-1, max(-6, d)) if d < 0 else PAIR_DELTA["INSULT"]
    for tag, words in PAIR_POS.items():
        if any(w in low for w in words):
            return tag, PAIR_DELTA[tag]
    if tone in ("COMPLIMENT", "I_AM_FRIENDLY", "THANKS", "GREETING"):
        return "FRIENDLY", max(1, min(4, d)) if d > 0 else 1
    if tone == "OFFER_HELP":
        return "SUPPORT", PAIR_DELTA["SUPPORT"]
    if isinstance(d, int) and d != 0:
        return ("FRIENDLY" if d > 0 else "ARGUE"), max(-4, min(4, d))
    return "NEUTRAL", 0


def context_rp(req):
    """v0.4.1 roleplay layer: the game already decided recruit / interrogation / romance / promise outcomes."""
    rp = req.get("rp") or {}
    if not isinstance(rp, dict):
        return []
    out = []
    if rp.get("doubt"):
        out.append("You're suspicious by nature: if they claim something big about themselves, you may doubt it or test "
                   "them with a pointed question before you believe it.")
    rec = rp.get("recruit")
    if isinstance(rec, list) and len(rec) >= 2:
        if rec[0]:
            out.append(f"They're asking you to join them and travel together. You agree ({_s(rec[1], 80)}). Say yes your own "
                       "way; act WALK_WITH_ME if offered.")
        else:
            out.append(f"They're asking you to join them. You refuse: {_s(rec[1], 100)}. Say no in character and give that "
                       "reason in your own words; act NONE.")
    intel = rp.get("intel")
    if isinstance(intel, list) and len(intel) >= 3:
        mode, text, why = intel[0], _s(intel[1], 160), _s(intel[2], 80)
        if mode in ("truth", "repeat") and text and not (len(intel) > 3 and intel[3]):
            out.append(f"They're pressing you for information. You tell them what you know: {text}. Use your own words, "
                       "vague like a rumour; add nothing else.")
        elif mode in ("lie", "repeat") and text:
            out.append(f"They're pressing you for information. You LIE and tell them: {text} - say it as if it were true; "
                       "never admit it's a lie, even if pushed.")
        elif mode == "ambush" and text:
            out.append(f"They're pressing you for information. You want them gone, so you send them into a trap: tell them "
                       f"there are {text}, as if doing them a favour. Never admit it's a trap.")
        elif mode == "none":
            out.append("They're asking about places or people you honestly know nothing about. Say so; don't make anything up.")
        else:
            why = why or "you don't trust them"
        out.append(f"They're pressing you for information. You won't tell them ({why}). "
                       "Refuse in character.")
    ask = rp.get("askOut")
    if isinstance(ask, list) and len(ask) >= 2:
        if ask[0]:
            out.append(f"They're asking you to be together, as a couple. You say yes ({_s(ask[1], 60)}): warm, a bit shy, tasteful.")
        else:
            out.append(f"They're asking you to be together, as a couple. Not now: {_s(ask[1], 100)}. Turn it down gently "
                       "in your own words.")
    fl = rp.get("flirt")
    if fl:
        out.append({"not looking": "They're flirting with you. You're not interested in that; deflect it in character.",
                    "too forward": "They're flirting with you and it feels too forward from someone you don't like much; "
                                   "brush it off, a bit put off.",
                    "unsure": "They're flirting with you. You're unsure about them; react cautiously, maybe a little amused.",
                    "welcome": "They're flirting with you and you don't mind it at all; flirt back a little, tasteful."}.get(fl, ""))
    st = rp.get("romance")
    st = int(st) if isinstance(st, (int, float)) else 0
    if st >= 1:
        out.append({1: "You've grown fond of them - a little warmer with them than with others.",
                    2: "You have a quiet crush on them: warm, a little shy around them, tasteful.",
                    3: "They are your partner: affectionate, protective of them, tender but never explicit."}.get(st, ""))
    new = rp.get("promiseNew")
    if isinstance(new, list) and len(new) >= 2:
        due = f" within {int(new[1])} hours" if isinstance(new[1], (int, float)) and new[1] >= 0 else ""
        out.append(f"They just promised you to {_s(new[0], 60)}{due}. React to the promise and hold them to it.")
    pr = [p for p in (rp.get("promises") or []) if isinstance(p, list) and len(p) >= 2]
    if pr and not new:
        out.append("Open promises they made you: " + "; ".join(
            _s(p[0], 50) + (f" (due in {int(p[1])} h)" if isinstance(p[1], (int, float)) and p[1] >= 0 else "") for p in pr[:3]) + ".")
    rec2 = rp.get("promiseRecord")
    if isinstance(rec2, list) and len(rec2) >= 2 and (rec2[0] or rec2[1]):
        out.append(f"They kept {int(rec2[0])} and broke {int(rec2[1])} of their promises to you."
                   + (" You don't fully trust their word." if rec2[1] else ""))
    if rp.get("attacked"):
        out.append("They have attacked you before; you remember it.")
    kept = rp.get("promiseKept")
    if kept:
        out.append(f"This keeps the promise they made you ({_s(kept, 60)}): you're pleased they kept their word.")
    return out


TIER_TONE = {
    "acquaintance": "polite, a little guarded - you don't know them that well yet",
    "friend": "friendly and easy with them",
    "close friend": "warm and open - you joke, share things, look out for them",
    "best friend": "fiercely loyal and unguarded - you'd tell them anything, and you'd take a bullet for them",
    "lover": "tender and close - they're your person (nothing explicit)",
}


def context_057(req):
    """v0.5.1.7: your bond tier with them, a decided answer (ask / step back / apology), shared history, likes and
    dislikes, a grudge, how months out here changed you, and your habits."""
    out = []
    bd = req.get("bond") or {}
    if isinstance(bd, dict) and bd:
        tier = bd.get("tier")
        if tier:
            out.append(f"You and them: {_s(tier, 20)}s (standing {int(bd.get('standing') or 0)}/100). Be {TIER_TONE.get(tier, 'yourself')}.")
        now = bd.get("now") or {}
        if isinstance(now, dict) and now.get("kind") == "ask":
            want = _s(now.get("want"), 20)
            if now.get("already"):
                out.append(f"They just asked if you could be {want}s - you already are. Say so.")
            elif now.get("ok"):
                out.append(f"They just asked if you could be {want}s. Your answer (already decided, say it): YES - {_s(now.get('why'), 100)}.")
            else:
                out.append(f"They just asked if you could be {want}s. Your answer (already decided, say it): NOT YET - {_s(now.get('why'), 120)}."
                           + (" It came too early: a little awkward, not hostile." if now.get("awkward") else " Be kind about it; you still like them."))
        elif isinstance(now, dict) and now.get("kind") == "step":
            out.append(f"They just told you they want to step back from {_s(now.get('from'), 20)}s to {_s(now.get('to'), 20)}s. "
                       + {"hurt": "It hurts, but you accept it.", "stung": "You're stung and a bit cold.", "shrugs": "You shrug it off.",
                          "accepts": "You accept it, a little sad."}.get(now.get("react"), "React."))
        elif isinstance(now, dict) and now.get("kind") == "apology":
            out.append("They just apologized. " + ("You accept it" if now.get("ok") else "You don't accept it yet")
                       + f" ({_s(now.get('why'), 100)}).")
        if isinstance(now, dict) and now.get("reveal") and not now["reveal"].get("pending"):  # 0.5.2.8: pending -> core
            rv = now["reveal"]
            if rv.get("none"):
                out.append("They asked what you like - you've told them the main things already; say something small.")
            else:
                out.append(("They asked what you like: tell them you love " if rv.get("like") else "They asked what bugs you: tell them you can't stand ")
                           + _s(rv.get("label"), 40) + ".")
        if isinstance(now, dict) and now.get("peeve"):
            out.append(f"What they just said hit a pet peeve of yours ({_s(now.get('peeve'), 30)}): let it show.")
        hist = [h for h in (bd.get("history") or []) if isinstance(h, str)]
        if hist:
            out.append("Shared history with them (newest first): " + "; ".join(_s(h, 60) for h in hist[:4]) + ".")
        likes = [x for x in (bd.get("likes") or []) if isinstance(x, str)]
        dis = [x for x in (bd.get("dislikes") or []) if isinstance(x, str)]
        if likes or dis:
            out.append("Your tastes (mention only when it fits): you like " + (", ".join(_s(x, 30) for x in likes) or "-")
                       + "; you can't stand " + (", ".join(_s(x, 30) for x in dis) or "-") + ".")
        gift = bd.get("gift") or {}
        if isinstance(gift, dict) and gift.get("label"):
            out.append(("Their gift was something you love: " if gift.get("like") else "Their gift was something you can't stand: ") + _s(gift.get("label"), 40) + ".")
        if bd.get("hint"):
            out.append(f"If it fits, hint that you'd call them a {_s(bd.get('hint'), 20)} now - don't ask outright.")
    gr = req.get("grudge") or {}
    if isinstance(gr, dict) and gr.get("why"):
        out.append(f"You hold a grudge against them: {_s(gr.get('why'), 80)} ({_s(gr.get('word'), 20)}). "
                   + {"revenge": "You want payback; cold and threatening.", "confront": "You're angry and you call it out.",
                      "avoid": "You're scared of them and want them gone; keep it short.",
                      "forgive": "It hurts, but you're trying to let it go."}.get(gr.get("style"), ""))
    ch = req.get("change") or {}
    if isinstance(ch, dict) and ch.get("state"):
        out.append(f"Months out here changed you: {_s(ch.get('line'), 60).lower()} ({_s(ch.get('word'), 20)}). Let it color how you talk.")
    ls = req.get("loss") or {}  # 0.5.2.7 [pt255u]: grieving undertone (fades over weeks)
    if isinstance(ls, dict) and ls.get("n"):
        d = int(ls.get("days") or 0)
        ago = "only yesterday" if d <= 1 else f"{d} days ago"
        how = {"cracking": "It broke something in you; you're fragile, gloomy, close to tears.",
               "hardened": "You shut it away; you've gone colder, curt, you don't talk about it.",
               "raging": "It turned to anger; you're short-fused and want someone to blame."}.get(ls.get("how"), "")
        out.append(f"You lost {_s(ls.get('n'), 40)} (your {_s(ls.get('t'), 30)}) {ago}. The grief is {_s(ls.get('level'), 40)}. {how}"
                   " Don't announce it; let it show in how you talk, and bring them up only when it fits.")
        if ls.get("trio"):
            out.append(f"You, {_s(ls.get('trio'), 60)} and {_s(ls.get('n'), 40)} were all together - the three of you, one family. "
                       f"{_s(ls.get('trio'), 60)} lost them too; that's shared, not a rivalry.")
        if ls.get("nobody"):
            out.append("They were the last person you had. You have nobody left.")
        if ls.get("alone"):
            out.append("You're afraid of losing anyone else; you cling a little to whoever is still here.")
    hb = req.get("habit") or {}
    if isinstance(hb, dict) and hb:
        bits = []
        if hb.get("smoker"):
            bits.append("you smoke" + (" and you're craving one" if hb.get("craving") else ""))
        if hb.get("drinker"):
            bits.append("you like a drink")
        if hb.get("teetotal"):
            bits.append("you don't drink")
        if bits:
            out.append("Habits: " + ", ".join(bits) + ".")
        if hb.get("askedSmoke"):
            out.append("You just asked them for a smoke.")
    return out


def context_051b(req):
    """v0.5.1: names, pauses, territory, threats, activities, the turned, trauma, weather, faction standing, reputation,
    love life, notes, losses, dead ties, settling, party, what the player wears, and the life / topic block."""
    out = []
    if req.get("useNames"):
        out.append("Only call people by names you actually know; otherwise don't use a name.")
    pa = req.get("pause") or {}
    if isinstance(pa, dict) and pa.get("secs"):
        out.append("You stopped what you were doing to hear them out" + (" - grudgingly" if pa.get("hostile") else "") + ".")
    te = req.get("territory") or {}
    if isinstance(te, dict) and te.get("kind"):
        out.append(f"Territory: {_s(te.get('kind'), 30)} (warning {int(te.get('step') or 1)}"
                   + (f", {_s(te.get('tier'), 20)}" if te.get("tier") else "") + "). Act on it in your words.")
    lo = req.get("leaveOrder") or {}
    if isinstance(lo, dict) and lo.get("how"):
        out.append(f"They told you to leave ({_s(lo.get('how'), 30)}).")
    th = req.get("threat") or {}
    if isinstance(th, dict) and th.get("kind"):
        out.append(f"They just threatened you ({_s(th.get('kind'), 20)}); it {_s(th.get('outcome'), 20)}"
                   + (f" ({_s(th.get('detail'), 60)})" if th.get("detail") else "") + ". Act accordingly.")
    pls = req.get("places") or []
    if isinstance(pls, list) and pls:
        out.append("Places your group has named (use these names): " + ", ".join(_s(p, 30) for p in pls[:8] if p) + ".")
    if req.get("placeOrder"):
        out.append(f"Right now you're {_s(req.get('placeOrder'), 60)} (they told you to).")
    ac = req.get("activity") or {}
    if isinstance(ac, dict) and ac.get("now"):
        out.append(f"What you're doing right now: {_s(ac.get('now'), 80)}." + (" They asked what you're up to - say so." if ac.get("asked") else ""))
    for t in (req.get("turned") or [])[:2]:
        if isinstance(t, dict) and t.get("name"):
            out.append(f"{_s(t.get('name'), 30)} died and came back as one of the dead"
                       + (" - someone put them down" if t.get("putDown") else "") + ".")
    pt = req.get("ptsd") or {}
    if isinstance(pt, dict) and pt.get("level"):
        out.append(f"You carry trauma ({_s(pt.get('why'), 60) or 'what you saw'})" + (": it's flaring right now - jumpy, short of breath" if pt.get("flare") else "") + ".")
    wx = req.get("weather2") or {}
    if isinstance(wx, dict) and wx:
        bits = [b for b, on in (("raining", wx.get("rain")), ("snowing", wx.get("snow")), ("foggy", wx.get("fog")), ("stormy", wx.get("storm"))) if on]
        if bits or isinstance(wx.get("temp"), (int, float)):
            out.append("Weather: " + (", ".join(bits) + ", " if bits else "") + (f"{int(wx['temp'])} C" if isinstance(wx.get("temp"), (int, float)) else "")
                       + (f", {_s(wx.get('season'), 12)}" if wx.get("season") else "") + ".")
    fr = req.get("factionRep") or {}
    if isinstance(fr, dict) and fr.get("name"):
        v = fr.get("v") or 0
        out.append(f"Your people ({_s(fr.get('name'), 30)}) {'like' if v > 0 else 'distrust'} the newcomer ({int(v)}).")
    rp = req.get("reputation") or {}
    if isinstance(rp, dict) and rp.get("titles"):
        out.append("You've heard of them as: " + ", ".join(_s(t, 40) for t in rp["titles"][:3]) + "."
                   + (" This is your first meeting." if rp.get("firstMeet") else ""))
    if req.get("loveLife"):
        out.append(f"Your love life: {_s(req.get('loveLife'), 100)}.")
    ln = req.get("lastNote") or {}
    if isinstance(ln, dict) and ln.get("body"):
        out.append(f"You recently left a note (\"{_s(ln.get('body'), 100)}\").")
    if req.get("losses"):
        out.append("People who died lately: " + "; ".join(_s(x, 80) for x in req["losses"][:3]) + ".")
    if req.get("deadTies"):
        out.append("DEAD (speak of them in the past tense, never as alive): " + "; ".join(_s(x, 90) for x in req["deadTies"][:4]) + ".")
    st = req.get("settle") or {}
    if isinstance(st, dict) and "ok" in st:
        out.append(("You agreed to move into their base (" if st.get("ok") else "You won't move into their base (") + _s(st.get("why"), 80) + "). Say so.")
    if req.get("settler"):
        out.append("You live at the newcomer's base now.")
    if req.get("settlerAway"):  # v0.5.1.8
        out.append("Right now you're out travelling with the newcomer; you still live at their base and will go back to it.")
    bp = req.get("baseParty") or {}
    if isinstance(bp, dict) and "ok" in bp:
        out.append(("They asked you to leave the base and travel with them and you agreed (" if bp.get("ok")
                    else "They asked you to leave the base and travel with them and you won't (") + _s(bp.get("why"), 90)
                   + "). Say so" + ("" if bp.get("ok") else " and explain - it's not about them") + ".")
    nb = req.get("npcBase") or {}  # v0.5.2: their own base
    if isinstance(nb, dict) and nb.get("name"):
        line = (f"You live at {_s(nb.get('name'), 40)}" + (f" near {_s(nb.get('place'), 30)}" if nb.get("place") else "")
                + f", a house your people made a base: {_s(nb.get('stage'), 40)}, {int(nb.get('members') or 0)} living there"
                + (", and you lead them" if nb.get("role") == "leader" else (f", led by {_s(nb.get('leader'), 30)}" if nb.get("leader") else ""))
                + f". Spirits: {_s(nb.get('morale'), 20)}; food: {_s(nb.get('food'), 24)}"
                + (f"; {_s(nb.get('goods'), 80)}" if nb.get('goods') else "")
                + (f"; your group is {_s(nb.get('power'), 60)}" if nb.get('power') else "")
                + (f"; how you live now: {_s(nb.get('living'), 80)}" if nb.get('living') else "")
                + (f"; your group is {_s(nb.get('road'), 90)}" if nb.get('road') else "")
                + (f"; your group is {_s(nb.get('wealth'), 30)} (what you have stored)" if nb.get('wealth') else "")
                + f". Toward the newcomer your people are {_s(nb.get('rep'), 24)}.")
        out.append(line)
        if nb.get("events"):
            out.append("Lately at home: " + "; ".join(_s(x, 80) for x in (nb.get("events") or [])[:3]) + ".")
        # Chat Plus directives: how your people run things, what they believe about outsiders, what they're working toward
        if nb.get("rule") or nb.get("creed"):
            out.append("How your group works: " + "; ".join(_s(x, 90) for x in (nb.get("rule"), nb.get("creed")) if x) + ".")
        if nb.get("allies") or nb.get("enemies"):
            out.append("Your people's ties: " + "; ".join(x for x in (
                ("friends/allies: " + ", ".join(_s(n, 40) for n in nb.get("allies")[:3])) if nb.get("allies") else "",
                ("enemies/rivals: " + ", ".join(_s(n, 40) for n in nb.get("enemies")[:3])) if nb.get("enemies") else "") if x) + ".")
        g = nb.get("goals") or {}
        if isinstance(g, dict) and any(g.values()):
            parts = [f"{k}: {_s(v, 60)}" for k, v in (("today", g.get("today")), ("this week", g.get("week")), ("this month", g.get("month"))) if v]
            out.append("What your people are working toward (" + "; ".join(parts) + "). It shapes your mood and what you talk about.")
        ch = nb.get("changed") or {}
        if isinstance(ch, dict) and ch.get("list"):
            out.append(f"The newcomer was last here about {int(ch.get('days') or 0)} days ago. Since then: "
                       + "; ".join(_s(x, 80) for x in (ch.get("list") or [])[-5:])
                       + ". If it fits, bring up what changed (who's gone, who's new, what you decided).")
        if nb.get("here"):
            out.append("The newcomer is at your base right now" + (" as your guest for the night." if nb.get("guest") else "."))
        elif nb.get("guest"):
            out.append("You agreed they can stay the night at your base.")
        if nb.get("raided"):
            out.append("The newcomer killed one of your people - you don't forget that.")
        elif nb.get("threatened"):
            out.append("Your base was attacked lately; if you trust the newcomer you might ask them for help.")
        out.append("Talk about home like a real place when it fits (invite friends, warn strangers off, ask for help); never invent other bases.")
    bn = req.get("basesNearby") or []
    if isinstance(bn, list) and bn:
        parts = []
        for b in bn[:2]:
            if isinstance(b, dict) and b.get("name"):
                parts.append(f"{_s(b.get('name'), 40)} ({int(b.get('members') or 0)} people"
                             + (f", led by {_s(b.get('leader'), 30)}" if b.get("leader") else "")
                             + (f", {_s(b.get('trouble'), 30)}" if b.get("trouble") else f", {_s(b.get('stage'), 30)}") + ")")
        if parts:
            out.append("Other survivor bases you've heard of (gossip, only if it comes up): " + "; ".join(parts) + ".")
    na = req.get("npcBaseAsk") or {}
    if isinstance(na, dict) and "ok" in na:
        if na.get("kind") == "stay":
            out.append(("They asked to stay the night at your base and you said yes (" if na.get("ok") else "They asked to stay the night at your base and you said no (")
                       + _s(na.get("why"), 90) + "). Say so.")
        else:
            out.append(("They asked your whole group to move into their base and you agreed (" if na.get("ok") else "They asked your whole group to move into their base and you refused (")
                       + _s(na.get("why"), 90) + "). Say so.")
    py = req.get("party") or {}
    if isinstance(py, dict) and py.get("size"):
        out.append(("You travel with the newcomer's party" if py.get("member") else "The newcomer travels with a party")
                   + (f" ({', '.join(_s(n, 20) for n in (py.get('others') or [])[:5])})" if py.get("others") else "") + ".")
    of = req.get("outfit") or {}
    if isinstance(of, dict) and of.get("desc"):
        line = f"The newcomer's look: {_s(of.get('desc'), 160)}."
        if of.get("recognized"):
            line += f" You know that look - it's them" + (f" (you call them {_s(of.get('nick'), 20)})" if of.get("nick") else "") + "."
        elif of.get("faceHidden"):
            line += " You can't see their face."
        elif of.get("face") in ("practical", "goggles", "gas"):
            line += " Practical survivor gear - mildly notable at most."
        out.append(line)
    tp = req.get("topic") or {}
    if isinstance(tp, dict) and tp.get("label"):
        t = f"Talk about: {_s(tp.get('label'), 60)}"
        if tp.get("fact"):
            t += f" - your truth: {_s(tp.get('fact'), 120)}"
        if tp.get("told"):
            t += " (you've told them this before: add something new or refer back to it)"
        if tp.get("theirs"):
            t += f". Theirs: {_s(tp.get('theirs'), 80)}"
        if tp.get("argue"):
            t += ". It's fine to disagree a little"
        if tp.get("mood") == "terse":
            t += ". Danger is near: keep it terse"
        out.append(t + ".")
        cb = tp.get("callback") or {}
        if isinstance(cb, dict) and cb.get("line"):
            out.append(f"Earlier, {_s(cb.get('who'), 30)} said about {_s(cb.get('topic'), 40)}: \"{_s(cb.get('line'), 90)}\" - you can call back to it.")
    lf = req.get("life") or {}
    if isinstance(lf, dict) and lf and not tp.get("label"):
        told = set(x for x in (lf.get("told") or []) if isinstance(x, str))
        facts = [f"{k}: {_s(lf[k], 60)}" for k in ("hometown", "job", "music", "show", "sport", "food", "hobby") if lf.get(k)]
        if facts:
            out.append("Your life before (reveal at most ONE detail, only if it fits): " + "; ".join(facts[:6]) + "."
                       + (" Already told them: " + ", ".join(sorted(told)[:6]) + "." if told else ""))
    bo = [x for x in (req.get("banOpeners") or []) if isinstance(x, str)]
    if bo:
        out.append("Do NOT start with: " + ", ".join('"' + _s(x, 30) + '"' for x in bo[:6]) + ".")
    return out


# v0.5.1: few-shot (style only, never content to copy) for small talk and replies
FEW_SHOT_AMBIENT = ("Examples of the voice (don't copy them): \"You ever eat at that diner off 31? Best pie in the county.\" | "
                    "\"My brother swore the Bulls would three-peat. Little shit was right.\" | "
                    "\"Quiet tonight. I hate quiet.\" | \"Remember what you said about your dad's truck? Saw one like it today.\"")
FEW_SHOT_REPLY = ("Examples of the voice (don't copy them): \"Depends. What're you trading?\" | \"Last guy who asked me that "
                  "tried to rob me.\" | \"Name's mine to keep for now.\" | \"Yeah, I can do that. Don't make me regret it.\"")


# 0.5.2.5 [pt252u]: "if you see any bandits shoot to kill" got "Least of our worries right now". A clear order /
# instruction now gets a rule that is never cut by prompt fitting (like the player's line itself, which is the user
# message, and who the NPC is + persona): answer THAT order - agree or refuse, in character. A reply that still
# ignores it (no yes/no and no word of the order) is retried once. Off: --no-order-rule or orderRule = false.
_ORDER_VERBS = (r"shoot|kill|attack|fire|guard|watch|stay|follow|go|come|wait|keep|hold|cover|get|grab|take|bring|drop|put|stop|"
                r"run|hide|check|help|listen|tell|warn|call|shout|leave|move|search|loot|scout|patrol|defend|protect|"
                r"avoid|ignore|lock|close|open|clear|kill|lead|meet|find|look|carry|pick|use|light|save|spare")
_ORDER_RX = re.compile(r"^\W*(?:(?:ok(?:ay)?|alright|hey|listen|look|so|now|and)[,\s]+)*(?:please[,\s]+)?"
                       r"(?:(?:i\s+want\s+you\s+to|i\s+need\s+you\s+to|you\s+need\s+to|you\s+should|you\s+better|"
                       r"you\s+have\s+to|you\s+gotta|make\s+sure\s+(?:you\s+)?|don'?t|do\s+not|never|always)\s+)?"
                       r"(?:" + _ORDER_VERBS + r")\b", re.I)
_ORDER_IF_RX = re.compile(r"^\W*(?:please[,\s]+)?(?:if|when|whenever|once|the\s+moment)\b[^.?!]{2,80}?[,\s]+"
                          r"(?:then\s+)?(?:you\s+)?(?:(?:just|always|please)\s+)?(?:" + _ORDER_VERBS + r")\b", re.I)
_ORDER_YESNO = re.compile(r"\b(yes|yeah|yep|yup|sure|ok(?:ay)?|alright|all right|fine|got it|copy|roger|understood|on it|will do|"
                          r"i will|i'll|you got it|count on|deal|consider it|no|nope|nah|not|won't|wouldn't|can't|cannot|"
                          r"never|don't|hell no|no way|forget it|if they|if it|only if|unless)\b", re.I)
_ORDER_STOP = {"that", "this", "with", "them", "they", "there", "then", "when", "what", "your", "just", "like", "have",
               "will", "would", "could", "should", "from", "into", "about", "anyone", "anybody", "something", "right", "here"}


def is_order(text):
    t = str(text or "").strip()
    if not t or t.endswith("?") or len(t) > 220:
        return False
    return bool(_ORDER_RX.search(t) or _ORDER_IF_RX.search(t))


def order_missed(order, say):
    """True when the reply neither agrees/refuses nor touches a word of the order."""
    if not say:
        return False
    if _ORDER_YESNO.search(say):
        return False
    words = {w for w in re.findall(r"[a-z']{4,}", order.lower()) if w not in _ORDER_STOP}
    stems = {w[:5] for w in words}
    for w in re.findall(r"[a-z']{4,}", say.lower()):
        if w in words or w[:5] in stems:
            return False
    return True


# 0.5.2.6 [pt254u]: who of theirs is DEAD - a fact block that prompt fitting never cuts (like the order rule). The mod
# sends deadFacts = [[name, word, how, day, fresh], ...] (max 3) for the people this NPC knows are dead. Without it a
# trimmed 2048-token prompt lost the grief lines and the NPC talked about a dead partner as if "still out cold".
def dead_facts(req):
    rows = req.get("deadFacts") if isinstance(req, dict) else None
    if not isinstance(rows, list) or not rows:
        return ""
    parts = []
    for r in rows[:3]:
        if not isinstance(r, list) or not r:
            continue
        name = _s(r[0], 40) or "someone"
        word = _s(r[1], 30) if len(r) > 1 and r[1] else ""
        how = _s(r[2], 80) if len(r) > 2 and r[2] else "died"
        day = r[3] if len(r) > 3 and isinstance(r[3], (int, float)) else None
        fresh = len(r) > 4 and r[4] in (1, True)
        txt = name + (f", your {word}" if word else "") + f" - {how}" + (f" (day {int(day)})" if day is not None else "")
        if fresh:
            txt += " (you just found out)"
        parts.append(txt)
    if not parts:
        return ""
    return ("DEAD (fact, you know this): " + "; ".join(parts) + ". Never talk as if they are alive, asleep, hurt, "
            "missing or 'out cold'; if they come up, they are gone.")


# 0.5.2.8 [pt265u]: THE CONVERSATION THREAD + the never-cut core. "when he said it should've been me i asked whats
# wrong and he talked about his leg": their own last line (req.lastLine), a short follow-up rule, how they feel right
# now (fresh grief beats a sore knee) and a pending "what do you like" answer are never cut by prompt fitting.
_FOLLOW_RX = re.compile(r"^\W*(?:no+|don'?t|dont|stop|why|how come|what'?s wrong|whats wrong|what'?s the matter|what do you mean|"
                        r"wdym|what happened|are (?:you|u) (?:ok|okay|alright|all right|good)|(?:you|u) (?:ok|okay|alright)|"
                        r"really|seriously|like what|such as|for example|give me (?:one|an example|some|a)|tell me (?:one|more|about it)|"
                        r"go on|and\b|huh|what\b|who\b|hey+|i'?m sorry|sorry)", re.I)


# 0.5.2.10 [pt270u]: A BITE IS NEVER FORGOTTEN. "josh got bit but doesnt care". The mod sends req.biteCore =
# {self: {spot, h, mode, devout, toc, amputated, told}, others: [{n, w, spot, h, how, from, st, stance}]} for the
# bitten NPC and for everyone who knows about someone's bite; prompt fitting never cuts these lines.
def _lst(x):
    return x if isinstance(x, list) else []


def _hrs(h):
    if not isinstance(h, (int, float)):
        return ""
    if h < 1:
        return f"{max(1, int(h * 60))} min ago"
    if h < 48:
        return f"{int(h)} h ago"
    return f"{int(h // 24)} days ago"


def bite_core(req):
    bc = req.get("biteCore") if isinstance(req, dict) else None
    if not isinstance(bc, dict):
        return []
    out = []
    me = bc.get("self")
    if isinstance(me, dict):
        spot = _s(me.get("spot"), 30) or "body"
        ago = _hrs(me.get("h"))
        t = (f"YOU ARE BITTEN (fact): a zombie bit you on the {spot}" + (f" ({ago})" if ago else "") + ". Everyone knows a bite "
             "almost always means the fever, death and turning. You are terrified and it colours everything: fear, despair, "
             "thinking about death, who you'd say goodbye to. Never shrug it off, never act fine.")
        mode = me.get("mode")
        told = [_s(x, 30) for x in _lst(me.get("told")) if _s(x, 30)]
        if mode == "hide":
            t += " You are hiding it: deny it or change the subject unless someone already knows" + (f" ({', '.join(told)} knows)" if told else "") + "."
        elif mode == "partner":
            t += " You only told the person closest to you; with others you keep it quiet" + (f" ({', '.join(told)} knows)" if told else "") + "."
        else:
            t += " You don't hide it: you'd tell people and ask for help" + (f" ({', '.join(told)} already knows)" if told else "") + "."
        if me.get("devout"):
            t += " You pray and lean on scripture (a Bible verse comes to you)."
        if me.get("amputated"):
            t += f" They took the limb ({_s(me.get('amputated'), 30)}) to stop it - you don't know yet if it worked."
        elif me.get("toc"):
            t += " Cutting the limb off fast might save you - you think about asking for it."
        out.append(t)
    hows = {"saw": "you saw it happen", "told": "they told you themselves", "heard": "you heard it"}
    for o in _lst(bc.get("others"))[:3]:
        if not isinstance(o, dict):
            continue
        n = _s(o.get("n"), 40) or "someone"
        w = _s(o.get("w"), 30)
        how = hows.get(o.get("how"), "you heard it")
        if o.get("how") == "heard" and _s(o.get("from"), 40):
            how = f"heard from {_s(o.get('from'), 40)}"
        ago = _hrs(o.get("h"))
        t = (f"{n} IS BITTEN (fact; {how})" + (f", on the {_s(o.get('spot'), 30)}" if o.get("spot") else "") + (f", {ago}" if ago else "")
             + "." + (f" You're their {w}." if w else ""))
        if _s(o.get("stance"), 200):
            t += f" How you take it: {_s(o.get('stance'), 200)}."
        out.append(t)
    if out:
        req["_biteCore"] = True
    return out


# 0.5.2.10 [pt270u]: A COUPLE SHARES ONE PAST. req.together = [{n, era, lines}] (how / when they met, the child, a
# late partner) - written by the mod from BOTH pasts, so the two never contradict each other. Never cut.
def major_core(req):
    """Chat Plus: the things a small model must never lose - never cut by the profile or prompt fitting."""
    out = []
    na = req.get("nameAsk") or {}
    if isinstance(na, dict) and na.get("how"):
        out.append({"real": f"They asked your name: tell them, it's {_s(na.get('name'), 30)}.",
                    "fake": f"They asked your name. You don't trust them: give the fake name {_s(na.get('name'), 30)}.",
                    "refuse": "They asked your name. You don't want to say it; dodge the question.",
                    "keepFake": f"You told them your name is {_s(na.get('name'), 30)} (a lie). Stay consistent.",
                    # Chat Plus: guarded answers
                    "first": f"They asked your name. You're guarded: give only your first name, {_s(na.get('name'), 30)}, nothing more.",
                    "yoursFirst": "They asked your name. You don't give it to strangers for free: ask for theirs first (or why they want it)."
                    }.get(na["how"], ""))
        if na.get("style"):
            out.append(_s(na.get("style"), 200))
    nb = req.get("npcBase") or {}
    if isinstance(nb, dict):
        if nb.get("secretAllies"):
            out.append("Your people have a quiet pact with " + ", ".join(_s(n, 40) for n in nb.get("secretAllies")[:2])
                       + (". You trust the newcomer enough that you might let it slip." if nb.get("secretOk") else ". Keep it to yourself; deny it if asked."))
        if nb.get("tributeDemanded"):
            out.append("Your people have demanded tribute (food) from the newcomer. If they bring it, good; if not, they'll be made to pay.")
        if nb.get("atWar"):
            out.append("Your people are at war with the newcomer. You are hostile; do not act friendly.")
        if nb.get("wantsJoin"):
            out.append("You've watched the newcomer cut down a horde of the dead for you. You want to join them; say so if it fits.")
    return out


def together_core(req):
    rows = req.get("together") if isinstance(req, dict) else None
    out = []
    for r in _lst(rows)[:2]:
        if not isinstance(r, dict):
            continue
        n = _s(r.get("n"), 40) or "your partner"
        lines = [_s(x, 260) for x in _lst(r.get("lines")) if _s(x, 260)]
        if not lines:
            continue
        out.append(f"YOUR PARTNER {n} - your shared past (fact, keep it consistent): " + " ".join(lines[:5]))
    if out:
        req["_together"] = True
    return out


def is_followup(said):
    s = (said or "").strip()
    if not s:
        return False
    return len(re.findall(r"[A-Za-z']+", s)) <= 4 or bool(_FOLLOW_RX.search(s))


def grief_active(req):
    ls = req.get("loss") or {}
    if not isinstance(ls, dict) or not ls.get("n"):
        return False
    g = ls.get("g")
    if isinstance(g, (int, float)):
        return g >= 0.2
    return not str(ls.get("level") or "").startswith("an old scar")


# 0.8.3 step 1: THE VISIT THREAD. The mod sends req.visit = {turns: [{w: "you"/"them", t, ago}], earlier: [topics],
# min} - every line of this visit before their current one ("you" = the player, "them" = this NPC). The last
# VISIT_KEEP lines are never cut; older ones go first when the prompt is too long (after general context).
VISIT_KEEP = 4


def visit_who(x):
    """who said a visit line: "You" (this NPC), "They" (the player), or another NPC there by name (0.8.3 step 9)."""
    w = x.get("w")
    if w == "them":
        return "You"
    if w == "other":
        return (_s(x.get("n"), 40) or "someone else") + " (with you)"
    return "They"


def visit_lines(req):
    """(older, recent): prompt lines for this visit's conversation so far, oldest first."""
    if req.get("mode") not in (None, "", "reply", "radio"):
        return [], []
    v = req.get("visit")
    if not isinstance(v, dict):
        return [], []
    turns = [x for x in _lst(v.get("turns")) if isinstance(x, dict) and _s(x.get("t"))]
    if not turns and not _lst(v.get("earlier")):
        return [], []

    def line(x):
        return f'- {visit_who(x)}: "{_s(x.get("t"), 200)}"'

    head = ["THIS CONVERSATION SO FAR (you, them and anyone else there, oldest first; they are answering the last of it now - keep it "
            "flowing, don't repeat yourself, don't re-introduce yourself or restart the talk):"]
    ea = [_s(x, 60) for x in _lst(v.get("earlier")) if _s(x)]
    if ea:
        head.append("Earlier in this talk they also brought up: " + "; ".join(ea) + ".")
    older = [line(x) for x in turns[:-VISIT_KEEP]] if len(turns) > VISIT_KEEP else []
    recent = head + [line(x) for x in turns[-VISIT_KEEP:]]
    req["_visit"] = len(turns)
    return older, recent


# 0.8.3 step 6: REMEMBERED THREADS. req.lastVisit = {agoH, how: walked/bye/trailed, turns: [{w, t}], earlier, q}
# - the last time this NPC and the player talked. Sent once, on the first line of a new visit.
LAST_HOW = {"walked": "you walked out on them", "bye": "you said goodbye", "trailed": "it just trailed off"}


def _ago_words(h):
    if not isinstance(h, (int, float)) or h < 1:
        return "less than an hour ago"
    if h < 24:
        return f"{int(h)} hour{'s' if int(h) != 1 else ''} ago"
    d = int(h // 24)
    return "yesterday" if d == 1 else f"{d} days ago"


def last_visit_lines(req):
    if req.get("mode") not in (None, "", "reply"):
        return []
    lv = req.get("lastVisit")
    if not isinstance(lv, dict):
        return []
    turns = [x for x in _lst(lv.get("turns")) if isinstance(x, dict) and _s(x.get("t"))]
    if not turns:
        return []
    head = (f"LAST TIME you two talked ({_ago_words(lv.get('agoH'))}), "
            + LAST_HOW.get(_s(lv.get("how"), 10), LAST_HOW["trailed"]) + ". How it ended:")
    out = [head] + [f'- {visit_who(x)}: "{_s(x.get("t"), 160)}"' for x in turns]
    ea = [_s(x, 60) for x in _lst(lv.get("earlier")) if _s(x)]
    if ea:
        out.append("Earlier that time they brought up: " + "; ".join(ea) + ".")
    if _s(lv.get("q")):
        out.append(f'You had asked them "{_s(lv.get("q"), 160)}" and they never answered.')
    out.append("You remember it. If it fits, you may bring it back up - once, naturally, in your own words (don't recite "
               "it). If it doesn't fit what they're saying now, let it go.")
    req["_lastVisit"] = True
    return out


def thread_core(req):
    """never-cut lines for a reply: what you just said, the follow-up rule, how you are now, a pending likes answer."""
    if req.get("mode") not in (None, "", "reply", "radio"):
        return []
    out = []
    ll = req.get("lastLine")
    vt = _lst((req.get("visit") or {}).get("turns")) if isinstance(req.get("visit"), dict) else []
    vlast = vt[-1] if vt and isinstance(vt[-1], dict) else None
    if (isinstance(ll, dict) and vlast is not None and vlast.get("w") == "them"
            and _s(vlast.get("t"), 160) == _s(ll.get("text"), 160)):
        if is_followup(req.get("said")):
            out.append("Their line is a follow-up to YOUR last line in the conversation above: answer it in that context "
                       "and stay on that topic. Don't change the subject.")
        req["_thread"] = True
        ll = None
    if isinstance(ll, dict) and _s(ll.get("text")):
        ago = ll.get("ago")
        t = f'You just said: "{_s(ll.get("text"), 160)}"' + (f" ({int(ago)} s ago)" if isinstance(ago, (int, float)) else "") + "."
        if ll.get("about"):
            t += f" That was about {_s(ll.get('about'), 120)}."
        if is_followup(req.get("said")):
            t += (" Their line is a follow-up to THAT: answer it in that context and stay on that topic (\"what's wrong\" or "
                  "\"are you okay\" = ask about what you just said; \"don't say that\" = they're answering your words; "
                  "\"give me one\" = an example of what you just named). Don't change the subject.")
        else:
            t += " Their message may be answering it; carry the conversation on from there."
        out.append(t)
        req["_thread"] = True
    if grief_active(req):
        ls = req["loss"]
        d = int(ls.get("days") or 0)
        firstn = (_s(ls.get("n"), 40).split() or ["them"])[0]
        out.append(f"How you are right now: grieving {_s(ls.get('n'), 40)} (your {_s(ls.get('t'), 30)}, lost "
                   + ("only yesterday" if d <= 1 else f"{d} days ago") + f"). That is what is on your mind, far more than any "
                   f"injury: if they ask how you are or what's wrong, it's about {firstn}, not a sore leg or a scrape.")
        req["_griefCore"] = True
    bd = req.get("bond") or {}
    now = bd.get("now") if isinstance(bd, dict) else None
    rv = now.get("reveal") if isinstance(now, dict) else None
    if isinstance(rv, dict) and rv.get("pending"):
        if rv.get("none"):
            out.append("They asked what you like - you've told them the main things already; say something small.")
        else:
            out.append(("They asked what you like: name " + _s(rv.get("label"), 40) + " as something you love - say the word."
                        if rv.get("like") else "They asked what bugs you: name " + _s(rv.get("label"), 40) + " - say the word."))
    return out


def order_rule(req):
    if req.get("orderRule") is False:
        return None
    if req.get("mode") not in (None, "", "reply", "radio"):
        return None
    said = _s(req.get("said"), 200)
    if not is_order(said):
        return None
    return (f"ORDER: they just told you to do something: \"{said}\". Answer THAT order directly - say you'll do it or you "
            "won't (a short reason or condition is fine), in your own voice and personality. Don't change the subject, "
            "don't brush it off with something unrelated. act stays NONE unless it is one of the listed actions.")


def apply_language(text, req):
    """0.5.1: the game's NPC language setting (req["lang"]: auto / en / es / ...). JSON keys and enum values stay English.
    0.8.11.2 (Kingston): the player may type any language; the NPC answers in the language of the player's line. The
    setting is only the fallback (no player line, or unsure)."""
    lang = (req or {}).get("lang") or "en"
    if not isinstance(text, str):
        return text
    said = (req or {}).get("said")
    if lang == "en":
        if not (isinstance(said, str) and said.strip()):
            return text
        return text + ("\nLANGUAGE: the newcomer may write in any language. Answer in the language of their last line "
                       "(English if unsure). Keep the JSON keys and the tone / act values in English; only \"say\" changes.")
    name = (req or {}).get("langName") or lang
    text = re.sub(r"\b1993 American\b", "1993 everyday", text)
    if lang == "auto":
        rule = ("LANGUAGE: answer in the same language the newcomer used in their last line (English if unsure or if they "
                "said nothing). Keep the JSON keys and the tone / act values in English; only \"say\" changes language.")
    else:
        rule = (f"LANGUAGE: the newcomer may write in any language. Answer in the language of their last line; when "
                f"there is none or you can't tell, speak {name}, naturally, the way a local survivor would talk if this "
                f"had happened where they live. Keep the JSON keys and the tone / act values in English; only \"say\" "
                f"changes language.")
    return text + "\n" + rule


def build_system(req):
    core = _build_system_core(req)
    more = PROMPTS.extra_for(req.get("mode"))  # 0.8.12: [extra] + [mode.<mode>] from the prompts files
    if more:
        core = core + "\n" + more
    return apply_language(core, req)


def _build_system_core(req):
    npc = req.get("npc") or {}
    w = req.get("world") or {}
    you = req.get("you") or {}
    name = _s(npc.get("name")) or "a survivor"
    sex = {"f": "woman", "m": "man"}.get(npc.get("sex"), "survivor")
    who = [f"You are {name}, a {sex} surviving in Knox County, Kentucky, July 1993, after the dead started walking."]
    role = _s(npc.get("title")) or _s(npc.get("role"))
    if role:
        who.append(f"Role: {role}" + (f" ({_s(npc.get('role'))})" if npc.get("title") and npc.get("role") else "") + ".")
    if npc.get("faction"):
        who.append(f"Group: {_s(npc['faction'])}.")
    tr = [x for x in (_s(npc.get("temper")), _s(npc.get("register"))) if x]
    if tr:
        who.append("Manner: " + ", ".join(tr) + ".")
    # v0.4.0 prompt-cache order: static rules -> who they are (persona, backstory) -> memory -> what is happening now
    static_who = list(who)
    who = []
    persona = persona_lines(req)
    doing = _s(npc.get("activity"))
    if doing and npc.get("goal") and npc.get("goal") not in ("hold",):
        doing += f" / {_s(npc['goal'])}"
    if doing:
        who.append(f"Doing now: {doing}" + (f", heading to {_s(npc['dest'])}" if npc.get("dest") else "") + ".")
    feel = []
    if npc.get("hurt"):
        feel.append("you are injured")
    if npc.get("scared"):
        feel.append("you are afraid")
    if npc.get("mood"):
        feel.append(f"mood {_s(npc['mood'])}")
    needs = req.get("needs") or {}
    for k in ("hungry", "thirsty", "hurt"):
        if isinstance(needs.get(k), str) and needs[k] not in feel:
            feel.append("you are " + _s(needs[k], 20))
    if feel and grief_active(req) and any("hurt" in f or "injur" in f or "sore" in f or "pain" in f for f in feel):
        feel.append("but that's minor next to your grief")  # 0.5.2.8 [pt265u]: the knee must not lead
    if feel:
        who.append("You: " + ", ".join(feel) + ".")
    drunk = npc.get("drunk")
    if isinstance(drunk, (int, float)) and drunk > 0:
        style = DRUNK_STYLE[0 if drunk < 20 else 1 if drunk < 45 else 2 if drunk < 70 else 3]
        who.append(f"You've been drinking ({_s(npc.get('drunkLabel'), 20) or 'tipsy'}): {style}")
    mates = [m for m in (req.get("mates") or []) if m]
    if mates:
        extra = int(req.get("mateCount") or len(mates)) - len(mates)
        who.append("Your people here: " + ", ".join(_s(m, 30) for m in mates) + (f" +{extra} more" if extra > 0 else "") + ".")

    t = []
    h = w.get("hour")
    if isinstance(h, (int, float)):
        h = int(h)
        t.append(f"{h:02d}:00 " + ("night" if h < 5 or h >= 21 else "morning" if h < 12 else "afternoon" if h < 18 else "evening"))
    if isinstance(w.get("day"), (int, float)):
        t.append(f"day {int(w['day'])} of the outbreak")
    if w.get("town"):
        t.append(f"near {_s(w['town'])}")
    if w.get("indoors"):
        t.append("indoors" + (f" ({_s(w.get('room'), 20)})" if w.get("room") else ""))
    rain = w.get("rain") or 0
    if isinstance(rain, (int, float)) and rain > 0.1:
        t.append("raining")
    if isinstance(w.get("fog"), (int, float)) and w["fog"] > 0.4:
        t.append("foggy")
    z = w.get("zombies")
    if isinstance(z, (int, float)):
        t.append("no zombies close" if z == 0 else f"{int(z)} zombies close" + (" - danger" if z >= 5 else ""))
    if w.get("zContact"):
        t.append("you just dealt with zombies")

    them = []
    if you.get("sex") in ("f", "m"):
        them.append("a woman" if you["sex"] == "f" else "a man")
    if you.get("holding"):
        them.append(f"holding a {_s(you['holding'], 30)}")
    elif w.get("armed"):
        them.append("armed")
    op = npc.get("op")
    rel = f"How you feel about them: {_s(npc.get('opLabel')).lower() or 'unsure of you'}"
    if isinstance(op, (int, float)):
        rel += f" (opinion {int(op)} of -100..100"
        if npc.get("opWhy"):
            rel += f"; {_s(npc['opWhy'], 70)}"
        rel += ")"
    rel += ". " + STANCE.get(npc.get("stance"), STANCE["neutral"])
    if not npc.get("known"):
        rel += " They don't know your name; give it only if you want to."
    if isinstance(op, (int, float)) and op < -25:
        rel += " You won't share information or help them."

    chatter = req.get("mode") in ("chime", "banter", "ambient")
    if req.get("mode") == "ambient":
        rel = "The newcomer nearby" + (" (" + ", ".join(them) + ")" if them else "") + " can hear you: " + rel
    elif chatter:
        rel = "About the newcomer nearby" + (" (" + ", ".join(them) + ")" if them else "") + ": " + rel
        toward = {"friendly": "on good terms with", "neutral": "neutral toward", "hostile": "hostile toward"}.get(req.get("toward"))
        line = req.get("line") or ["someone", ""]
        if toward and line and line[0] not in ("Them",):
            rel += f" You are {toward} {_s(line[0], 40)}" + (" (same side)" if req.get("sameSide") else "") + "."
    memory = req.get("_memory") or ""
    lines = [STATIC_HEAD, " ".join(static_who)] + persona
    # 0.5.2.2: parts that may be cut when the prompt would not fit num_ctx (lowest rank goes first). The rules, who
    # they are, their persona, the situation and the closing instruction are never cut.
    drop = []
    if memory:
        lines.append(memory)  # v3: persistent memory from alifetalk_mem (replaces the short in-save list)
        drop.append((90, len(lines) - 1, "memory"))
    lines.append("\n".join(x for x in [" ".join(who), "Now: " + ", ".join(t) + "." if t else "",
                        ("" if chatter else "The person talking to you" + (" (" + ", ".join(them) + ")" if them else "") + ": ") + rel] if x))
    earlier = [] if memory else (req.get("earlier") or [])
    if earlier:
        drop.append((30, len(lines), "earlier"))
        lines.append("Earlier with them: " + " | ".join(
            f"day {e[0]}: they said \"{_s(e[1], 90)}\", you said \"{_s(e[2], 90)}\"" for e in earlier if isinstance(e, list) and len(e) >= 3))
    heard = req.get("heard") or []
    if heard:
        drop.append((75, len(lines), "heard"))
        lines.append("Just said nearby (oldest first):\n" + "\n".join(
            f"- {_s(h[0], 40)}: \"{_s(h[1], 140)}\"" for h in heard if isinstance(h, list) and len(h) >= 2))
    for rank, block in ((70, context_v32(req, npc)), (50, context_rp(req)), (45, context_050(req)), (40, context_051(req)),
                        (35, context_051b(req)), (33, context_057(req))):
        for x in block:  # inside a block the later lines go first
            drop.append((rank + 0.001 * len(lines), len(lines), "context"))
            lines.append(x)
    dfacts = dead_facts(req)
    if dfacts:
        lines.append(dfacts)  # 0.5.2.6 [pt254u]: never in `drop` - every mode, prompt fitting can't cut it
        req["_deadFacts"] = True
    for x in last_visit_lines(req):
        drop.append((60, len(lines), "last visit"))  # 0.8.3 step 6: cut before general context (its last lines first)
        lines.append(x)
    v_old, v_recent = visit_lines(req)
    for x in v_old:
        drop.append((75 + 0.001 * len(lines), len(lines), "visit (older lines)"))  # 0.8.3: cut after general context
        lines.append(x)
    for x in v_recent:
        lines.append(x)  # 0.8.3: last VISIT_KEEP lines of this visit, never in `drop`
    for x in thread_core(req):
        lines.append(x)  # 0.5.2.8 [pt265u]: never in `drop`
    an = answering_core(req)
    if an:
        lines.append(an)  # 0.8.3 step 4: never in `drop`
        req["_core"] = True
    for x in major_core(req):
        lines.append(x)  # Chat Plus: never in `drop` (names, tribute, war, pacts, join offers)
    for x in together_core(req) + bite_core(req):
        lines.append(x)  # 0.5.2.10 [pt270u]: never in `drop` (every mode)
    if req.get("mode") in CHATTER_MODES:
        drop.append((10, len(lines), "examples"))
        lines.append(FEW_SHOT_AMBIENT)
    elif req.get("mode") in (None, "", "reply"):
        drop.append((10, len(lines), "examples"))
        lines.append(FEW_SHOT_REPLY)
    drop.append((20, len(lines), "filler rule"))
    lines.append("Never use filler like \"stay safe out there\", \"we're all in this together\" or \"one day at a time\".")
    if req.get("mode") == "letter":
        rc = req.get("react") or {}
        lines.append(f"RIGHT NOW: {_s(rc.get('what'), 200)}. WRITE a short handwritten note (max 40 words), in your own voice, "
                     "plain 1993 American, no narration. Put the note text in \"say\". JSON: tone NONE, act NONE, d 0, leave false.")
        return fit_lines(lines, drop, req)
    if req.get("mode") == "thought":
        rc = req.get("react") or {}
        sx = you.get("sex")
        pr = {"m": ("him", "The newcomer is a man: call him he/him/his/himself every time - never \"they\". "),
              "f": ("her", "The newcomer is a woman: call her she/her/her/herself every time - never \"they\". ")}.get(sx, ("them", ""))
        lines.append(f"RIGHT NOW: {_s(rc.get('what'), 300)}. WRITE ONE sentence, first person, max 28 words: what you honestly think of "
                     f"{pr[0]} right now, in your own voice (plain 1993 American, no narration, no quotes). {pr[1]}Put it in \"say\". "
                     "JSON: tone NONE, act NONE, d 0, leave false.")  # 0.5.2.5 [pt252u]: consistent pronouns
        return fit_lines(lines, drop, req)
    hints = [h for h in (req.get("actHints") or []) if isinstance(h, str)]
    if req.get("mode") in REACT_MODES:
        rc = req.get("react") or {}
        mw = int(rc.get("maxWords") or 14) if isinstance(rc.get("maxWords"), (int, float)) else 14
        lines.append(
            f"RIGHT NOW: {_s(rc.get('what'), 200)}. Say ONE short line out loud, max {mw} words"
            + (f" ({_s(rc.get('style'), 160)})" if rc.get("style") else "")
            + ". Fit who you are and your bond with the people involved. Plain 1993 American speech, no narration, "
            "no asterisks, never mention AI or games, don't invent places or events. "
            + ("You MUST say something - never an empty line. " if req.get("mode") in MUST_SPEAK else
               "If a real person would honestly stay quiet, say \"\". ")
            + "JSON: tone NONE, act NONE, d 0, leave false.")
        sr = standoff_rule(req)
        if sr:
            lines.append(sr)
        return fit_lines(lines, drop, req)
    if req.get("mode") == "death":
        ev = req.get("event") or {}
        tie = {"group": "one of your own group", "friend": "a friend of yours", "side": "someone on your side",
               "enemy": "someone you were against", "stranger": "a stranger"}.get(ev.get("tie"), "someone")
        killer = "the person standing near you (the newcomer)" if ev.get("killerUid") == "player" else _s(ev.get("killer"), 40)
        lines.append(
            f"RIGHT NOW: {_s(ev.get('victim'), 40)}, {tie}, was just killed by {killer}. React out loud in the moment, "
            "ONE short line, max 14 words, like a real person: grief, shock, rage or fear, as strong as your tie to them "
            "(a stranger's death shakes you less; an enemy's barely)." + (" You are furious and afraid of the killer."
            if ev.get("killerUid") == "player" and ev.get("tie") in ("group", "friend") else "")
            + (f" They were your {_s(ev.get('bond'), 30)}." if ev.get("bond") else "")
            + (" You are in the middle of a fight: a raw combat bark, max 8 words - rage or panic." if ev.get("fight") else "")
            + (" You're drunk: it hits you even harder." if isinstance(npc.get("drunk"), (int, float)) and npc["drunk"] >= 45 else "")
            + " No narration, no asterisks. JSON: tone NONE, act NONE, d 0, leave false.")
        return fit_lines(lines, drop, req)
    if req.get("mode") == "ambient":
        lines.append(person_line(req.get("partner") or {}, "The person next to you"))
        lines.append(
            "Nobody is talking to you right now. Say ONE short line, max 18 words, out loud to "
            f"{_s((req.get('partner') or {}).get('name'), 40) or 'them'}: small talk, a gripe, a joke, a worry about "
            "the situation, or something from your shared history - whatever fits who you both are and how you get "
            "along. Plain 1993 American speech, no narration, never mention AI or games, don't invent places or "
            "events. If you'd honestly stay quiet now, say \"\". " + PAIR_JSON)
        return fit_lines(lines, drop, req)
    if chatter:
        lines.append(
            "You just overheard the line below. If a real person in your spot would naturally add something (agree, "
            "joke, warn, disagree, tease a friend, answer a question), say ONE short sentence, max 18 words, plain "
            "1993 American speech, out loud. Otherwise stay quiet: say \"\". Don't repeat what was said, don't narrate, "
            "never mention AI or games, don't invent places or events. "
            + (PAIR_JSON if req.get("speakerUid") and req.get("lineTo") != "you" else "JSON: tone NONE, act NONE, d 0, leave false."))
        return fit_lines(lines, drop, req)
    if req.get("mode") == "gift":
        g = req.get("gift") or {}
        lines.append(
            "Just now they handed you something (see their message). React out loud like a real person, 1-2 short "
            "sentences, max 22 words, plain 1993 American speech, no narration or asterisks: grateful if you need it "
            "or it's valuable, warm if you like them, puzzled or a bit insulted by junk or rotten stuff, wary if you "
            "don't trust them" + (", embarrassed if they keep giving you things" if (g.get("before") or 0) >= 2 else "")
            + (". It's a trade, so talk about the deal" if g.get("trade") else "")
            + (f". It's the {_s(g.get('asked'), 20)} you asked them for - they remembered" if g.get("asked") else "")  # 0.8.3 step 10
            + ". "
            + ("If it's alcohol and you'd honestly want a drink right now (safe, not on watch, you like drinking), "
               "act DRINK and say something as you take a swig; otherwise act NONE. " if hints else "act NONE. ")
            + "JSON: tone NONE, leave false, d = -3..2 only for how the gesture itself lands (0 if ordinary).")
        return fit_lines(lines, drop, req)
    fight = req.get("fight") or {}
    if fight_vs_dead(req) and req.get("mode") in (None, "", "reply"):
        # 0.8.11.2 (Miller): fighting the dead, the newcomer is not your enemy. A shout from them is about the danger.
        lines.append(
            "You are busy fighting the dead right now. Answer with a SHORT shout, max 12 words. If the newcomer yells "
            "\"get out of here\", \"back off\", \"run\", \"move\", \"behind you\" or the like, that is a WARNING about "
            "the dead, not a threat to you: react to the danger (run, pull back, shout about the zombies, thank them "
            "or brush them off) - never take it as an attack. Only real insults or threats against YOU count as hostile. "
            "JSON: tone NONE unless their line is a clear insult (INSULT) or a clear threat to you (THREATEN); act NONE; "
            "d 0..3 for a warning or for help in the fight, negative only for a real insult or threat; leave false.")
        return fit_lines(lines, drop, req)
    if (fight.get("hostile") or fight.get("fighting")) and req.get("mode") in (None, "", "reply"):
        lines.append(
            "You are " + ("hostile toward them" if fight.get("hostile") else "busy fighting") + " right now. Answer with "
            "a SHORT combat bark, max 12 words: a threat, a taunt, an order, a curse - or, only if they plead AND you "
            "are hurt, outnumbered or not that set against them, a moment of hesitation (\"...why should I believe "
            "you?\"). Never turn friendly all of a sudden. Insults make you angrier. JSON: tone = how THEIR line came "
            "across (SORRY/I_AM_FRIENDLY if they plead or offer peace, INSULT, THREATEN, else NONE), act NONE, "
            "d -10..3 (positive only for a sincere plea), leave false.")
        return fit_lines(lines, drop, req)
    if req.get("mode") == "radio":
        lines.append(
            "RADIO: this is a walkie-talkie call. They are NOT with you; you can't see them and they can't see you "
            "(ignore anything about what they hold or look like). Answer like a real radio call: 1 short clipped "
            "sentence, max 16 words, radio habits (\"copy\", \"go ahead\", end with \"over\"), now and then a burst "
            "of static written as *kssht*. You can still bring up shared memories, gifts and things you saw. "
            "If you don't want to talk to them, say so briefly and set leave true.")
    orule = order_rule(req)
    if orule:
        lines.append(orule)  # 0.5.2.5: never in `drop` - prompt fitting can't cut it
        req["_order"] = True
    # 0.5.2.11: soft classifier / unknown GIST from game (weak model support)
    gist = req.get("gist")
    reason = (req.get("reason") or "").strip().lower()
    if gist and req.get("gistSoft") and reason != "unknown":
        lines.append("HINT (what they probably mean; answer in your own way, your own words): " + _s(gist, 300))
        req["_gist"] = True
    elif gist:
        lines.append("GIST (obey this meaning; do not invent beyond it): " + _s(gist, 300))
        req["_gist"] = True
    if reason == "unknown":
        lines.append(
            "REASON unknown: you did not understand a clear request. One short clarifying question or wary "
            "acknowledgment only. Do not agree, offer, direct, or invent. Examples: \"What was that?\" "
            "\"Say that again?\" \"What do you need?\"")
        req["_unknown"] = True
    soft_tone = req.get("softTone")
    if soft_tone:
        lines.append(f"Their line came across as {soft_tone}. Let that color your reply.")
    lines.append(
        "Reply as yourself, out loud: " + reply_length(req) + ", plain 1993 American speech. No narration, "
        "no asterisks, never mention AI or games. Stay consistent with what was just said; if you were talking "
        "about something, you may mention it. Don't invent game facts (items, stock, who is where); small personal "
        "color is fine if it stays consistent. "
        "If they ask you something or make small talk, ANSWER IT like a normal person would (how your day is, "
        "what you think, who you are). You may mention danger in passing only if zombies are close right now; "
        "don't keep steering every answer back to zombies or a horde. "
        "React like a real person: rudeness annoys you, threats make you defensive or scared, kindness warms you. "
        "Most lines are ordinary chat: then tone NONE, act NONE, d 0, leave false.\n"
        "JSON fields: tone = how THEIR line came across (GREETING for hi/howdy, THANKS, SORRY only if they apologise, "
        "INSULT only if they insult you, THREATEN only if they threaten to hurt you, GO_AWAY only if they tell you "
        "to leave; otherwise NONE). act = an action ONLY if their line literally asks for it"
        + (": " + "; ".join(hints) if hints else "") + "; else NONE (if you refuse, use NONE). "
        "d = opinion change for THEIR line: 0 for small talk/questions/greetings, +1..+3 polite or friendly, "
        "+4..+7 real help/kindness, -1..-3 mild rudeness, -4..-7 real insults, -8..-10 death threats. Never negative "
        "for a friendly or ordinary line. leave = true ONLY if they told you to go, said goodbye, or were hostile.")
    cr = command_rule(req)
    if cr:
        drop.append((18, len(lines), "commands"))  # 0.8.2 part 2
        lines.append(cr)
    wr = want_rule(req)
    if wr:
        drop.append((17, len(lines), "wants"))  # 0.8.3 step 10
        lines.append(wr)
    gr = gesture_rule(req)
    if gr:
        drop.append((17, len(lines), "gesture"))  # 0.8.3 step 7
        lines.append(gr)
    ar = askback_rule(req)
    if ar:
        drop.append((16, len(lines), "ask back"))  # 0.8.3 step 4
        lines.append(ar)
    sl = suggest_rule(req)
    if sl:
        drop.append((15, len(lines), "suggestions"))  # 0.8.3: first thing cut after the examples
        lines.append(sl)
    return fit_lines(lines, drop, req)


# 0.5.2.2: PROMPT BUDGET. num_ctx is 2048 tokens by default and rich scenes went past it; Ollama then silently cut the
# START of the prompt (the rules and who the NPC is). Now the optional parts are trimmed first so the whole prompt plus
# the reply (num_predict) always fits. Chars per token is estimated low on purpose (names, JSON words).
CHARS_PER_TOKEN = 3.3
PROMPT_MARGIN_TOKENS = 140  # chat template, the user line wrapper, a retry's hint
FIT_STATS = {"fitted": 0, "cut": 0}
CTX_TIP = {"shown": False}
DEFAULT_NUM_CTX = 4096  # 0.5.2.8 [pt265u]: was 2048 (rich scenes had to be trimmed); falls back to 2048 if Ollama can't


def setup_files():
    """0.8.12: the game's AI tab writes Zomboid/Lua/alifeai_setup.txt; it wins over model.txt (and survives mod updates)."""
    return [os.path.join(default_dir(), "alifeai_setup.txt"),
            os.path.join(os.path.dirname(os.path.abspath(__file__)), "model.txt")]


def model_setting(key, default=None):
    """0.8.11.2: a key=value line in model.txt (num_ctx=, warmup=, fallback=). The PowerShell bridge reads the same file,
    so both ask Ollama for the same num_ctx and the model is never reloaded between them. 0.8.12: alifeai_setup.txt first."""
    for mt in setup_files():
        try:
            with open(mt, "r", encoding="utf-8-sig", errors="ignore") as f:
                for ln in f:
                    m = re.match(r"\s*" + re.escape(key) + r"\s*=\s*(\S+)", ln)
                    if m:
                        return m.group(1)
        except Exception:
            pass
    return default


def resolve_num_ctx(args):
    """--num-ctx not given (0) -> model.txt num_ctx= or 4096, with a one-time fallback to 2048 if Ollama errors
    (Ollama.ctx_fallback; only for the built-in default)."""
    if not int(getattr(args, "num_ctx", 0) or 0):
        mt = model_setting("num_ctx")
        try:
            mt = int(mt) if mt else 0
        except ValueError:
            mt = 0
        args.num_ctx = mt or DEFAULT_NUM_CTX
        args.ctx_auto = not mt
    else:
        args.ctx_auto = False
    return args.num_ctx


def prompt_char_budget(args, user="", extra=""):
    """characters the system prompt may use (None = no limit known)."""
    try:
        ctx = int(getattr(args, "num_ctx", 2048) or 2048)
        pred = int(getattr(args, "num_predict", 80) or 80)
    except Exception:
        return None
    tokens = ctx - pred - PROMPT_MARGIN_TOKENS
    return max(1200, int(tokens * CHARS_PER_TOKEN) - len(user or "") - len(extra or ""))


def _trim_memory(text, over):
    """cut a memory block from its end (older recalls, events, overheard lines go first; the summary stays)."""
    parts = text.split("\n")
    while len(parts) > 1 and over > 0:
        over -= len(parts.pop()) + 1
    t = "\n".join(parts)
    if over > 0:
        t = t[:max(0, len(t) - over)].rsplit(" ", 1)[0]
    return t


# Chat Plus: PERFORMANCE PROFILE. Small models get confused by a prompt full of politics, so they get only what matters
# most (who they are, the situation, you, memory); big models get everything. lite / normal / full - picked from the
# model's size, or set "profile=lite|normal|full" on any line of model.txt. Major events never depend on this: the game
# says them out loud itself and they ride in the uncuttable core.
PROFILES = {"lite": {"cap": 0.45, "floor": 50}, "normal": {"cap": 0.75, "floor": 0}, "full": {"cap": 1.0, "floor": 0}}


def pick_profile(model, override=""):
    o = (override or "").strip().lower()
    if o in PROFILES:
        return o
    # 0.8.12: the game's AI tab (alifeai_setup.txt, profile=auto|lite|normal|full) first, then model.txt
    mp = (model_setting("profile") or "").strip().lower()
    if mp in PROFILES:
        return mp
    name = (model or "").lower()
    if "mistral-nemo" in name:
        return "full"
    m = re.search(r"(?:^|[^a-z0-9])e?(\d+(?:\.\d+)?)b\b", name.replace(":", " ").replace("-", " "))
    size = float(m.group(1)) if m else 4.0
    if size <= 3.5:
        return "lite"
    if size <= 5.5:
        return "normal"
    return "full"


def apply_profile(lines, drop, req):
    prof = PROFILES.get(req.get("_profile") or "normal", PROFILES["normal"])
    if prof["floor"] > 0:
        keep = []
        for d in drop:
            if d[0] < prof["floor"] and d[2] != "memory":
                lines[d[1]] = ""
            else:
                keep.append(d)
        drop[:] = keep
    b = req.get("_maxChars")
    if isinstance(b, (int, float)) and prof["cap"] < 1.0:
        req["_maxChars"] = max(1200, int(b * prof["cap"]))


def fit_lines(lines, drop, req):
    lines = list(lines)
    if isinstance(req, dict):
        try:
            apply_profile(lines, drop, req)
        except Exception:
            pass
    budget = req.get("_maxChars") if isinstance(req, dict) else None
    text = "\n".join(x for x in lines if x)
    if not isinstance(budget, (int, float)) or len(text) <= budget:
        return text
    lines = list(lines)
    cut = []
    for rank, idx, what in sorted(drop, key=lambda d: (d[0], -d[1])):
        over = len("\n".join(x for x in lines if x)) - budget
        if over <= 0:
            break
        if not lines[idx]:
            continue
        if what == "memory":
            lines[idx] = _trim_memory(lines[idx], over)
            cut.append("memory (trimmed)")
        else:
            lines[idx] = ""
            cut.append(what)
    text = "\n".join(x for x in lines if x)
    FIT_STATS["fitted"] += 1
    FIT_STATS["cut"] += len(cut)
    req["_cut"] = cut
    return text


BANNED = re.compile(r"\b(as an ai|language model|chatgpt|openai|llama|i'm an ai|i am an ai)\b", re.I)


_LIST_LINE = re.compile(r"^\s*(?:\(?\d{1,2}[.):]|[-*\u2022]|option\s+\d+\s*[:.)-]?)\s+(.*)$", re.I)
_MARKUP = re.compile(r"\\+[a-z]+\s*\{[^{}]{0,40}\}|<\s*/?\s*(?:rgb|size|line|br|center|left|right|img|text|h\d?)\b[^>]{0,60}>|"
                     r"\[\s*/?\s*(?:col|img|b|i|u|color)\b[^\]]{0,40}\]|\[\s*/\s*\]", re.I)


def one_line(text):
    """0.5.2.3: a spoken line is ONE line. Small models sometimes answer with a menu ("1. Head north 2. Stay put")
    or several lines - keep the lead-in sentence if there is one, else the first option, without its number."""
    text = str(text or "")
    lines = [x.strip() for x in text.replace("\r", "\n").split("\n") if x.strip()]
    items = [(i, _LIST_LINE.match(x)) for i, x in enumerate(lines)]
    listed = [i for i, m in items if m]
    if len(listed) >= 2 or (listed and listed[0] == 0 and len(lines) == 1):
        lead = " ".join(lines[:listed[0]]).strip()
        lead = lead.rstrip(":").strip()
        if lead and not re.search(r"\b(options?|choices?|either|you can|you could|here are)\b\W*$", lead, re.I) \
                and len(lead) >= 8:
            text = lead if re.search(r"[.!?]$", lead) else lead + "."
        else:
            text = items[listed[0]][1].group(1)
    elif len(lines) > 1:
        text = " ".join(lines)
    # the same menu written inline: "... 1. Go north. 2. Stay here. 3. ..."
    m = re.search(r"(?:^|\s)\(?1[.)]\s+(.+?)\s+\(?2[.)]\s+", text)
    if m:
        lead = text[:m.start()].strip().rstrip(":").strip()
        if lead and len(lead) >= 8 and not re.search(r"\b(options?|choices?|either|you can|you could|here are)\b\W*$", lead, re.I):
            text = lead if re.search(r"[.!?]$", lead) else lead + "."
        else:
            text = m.group(1)
    text = text.strip()
    return text[:1].upper() + text[1:] if text else text


# 0.5.2.5 [pt252u]: lines ABOUT the player keep one set of pronouns (the player's gender). Wrong-gender forms are
# swapped; singular "they" mixed with gendered forms is made gendered, verb included. A line that only says "they" is
# left alone. Same rules as ALifeLLMTalk.fixPronouns (Bond.lua).
_P_MALE = {"he": "he", "him": "him", "his": "his", "himself": "himself", "he's": "he's", "he'd": "he'd", "he'll": "he'll"}
_P_FEM = {"she": "he", "her": "her*", "hers": "hers", "herself": "himself", "she's": "he's", "she'd": "he'd", "she'll": "he'll"}
_P_THEY = {"they": "he", "them": "him", "their": "his", "theirs": "hers", "themselves": "himself", "themself": "himself",
           "they're": "he's", "they've": "he's", "they'd": "he'd", "they'll": "he'll"}
_P_SETS = {"m": {"he": "he", "him": "him", "his": "his", "himself": "himself", "hers": "his", "he's": "he's", "he'd": "he'd", "he'll": "he'll"},
           "f": {"he": "she", "him": "her", "his": "her", "himself": "herself", "hers": "hers", "he's": "she's", "he'd": "she'd", "he'll": "she'll"}}
_P_VERB = {"are": "is", "were": "was", "have": "has", "do": "does", "don't": "doesn't", "aren't": "isn't", "weren't": "wasn't",
           "haven't": "hasn't", "go": "goes", "try": "tries", "carry": "carries", "watch": "watches", "catch": "catches", "fix": "fixes",
           "miss": "misses"}
for _v in ("seem look know think want need say keep act talk come mean get make take pull help work listen fight shoot run walk "
           "stick hold show care remind sound feel like deserve earn owe pay handle move smile laugh stay leave give bring hide lie "
           "tell ask").split():
    _P_VERB[_v] = _v + "s"
_P_ADV = {"just", "really", "never", "always", "still", "probably", "sure", "actually", "clearly", "obviously", "only", "also"}
_P_NOTNOUN = {"and", "or", "but", "to", "up", "out", "off", "in", "on", "at", "for", "with", "again", "now", "yet", "too", "down",
              "alone", "back", "go", "be", "the", "a", "an", "is", "was", "so", "much", "here", "there"}


def _p_case(orig, rep):
    return rep[:1].upper() + rep[1:] if orig[:1] != orig[:1].lower() else rep


def fix_pronouns(text, sex):
    if not isinstance(text, str) or sex not in ("m", "f"):
        return text
    toks = [[t, bool(re.match(r"[A-Za-z']", t))] for t in re.findall(r"[A-Za-z']+|[^A-Za-z']+", text)]
    own, other = (_P_MALE, _P_FEM) if sex == "m" else (_P_FEM, _P_MALE)
    words = [k for k, t in enumerate(toks) if t[1]]
    low = [toks[k][0].lower() for k in words]
    has_own = any(w in own for w in low)
    has_other = any(w in other and w not in own for w in low)
    has_they = any(w in _P_THEY for w in low)
    group = any(w in ("all", "both", "people", "folks") for w in low)
    if not (has_own or has_other):
        return text
    S = _P_SETS[sex]
    changed = False
    for wi, k in enumerate(words):
        lw = low[wi]
        nw = low[wi + 1] if wi + 1 < len(low) else None
        rep = None
        if has_other and lw in other and lw not in own:
            base = other[lw]
            if sex == "m":
                if base == "her*":
                    base = "his" if (nw is not None and nw not in _P_NOTNOUN and nw not in _P_VERB) else "him"
                rep = S.get(base, base)
            else:
                rep = ("hers" if (nw is None or nw in _P_NOTNOUN) else "her") if lw == "his" else S.get(lw, lw)
        elif has_they and not group and lw in _P_THEY:
            rep = S.get(_P_THEY[lw], _P_THEY[lw])
            if lw == "they":
                j = wi + 1
                while j < len(low) and low[j] in _P_ADV:
                    j += 1
                if j < len(low) and low[j] in _P_VERB:
                    vk = words[j]
                    toks[vk][0] = _p_case(toks[vk][0], _P_VERB[low[j]])
        if rep and rep != lw:
            toks[k][0] = _p_case(toks[k][0], rep)
            changed = True
    return "".join(t[0] for t in toks) if changed else text


# 0.7.0.1: small models sometimes leak their reasoning or the prompt's rules into the line ("...through."} 12 words max.
# This is a single response."). Thinking blocks, JSON leftovers and sentences about the reply itself are dropped.
_THINK = re.compile(r"<think>.*?</think>|<\|?(?:thinking|reasoning)\|?>.*?<\|?/(?:thinking|reasoning)\|?>", re.I | re.S)
_JSON_TAIL = re.compile(r'["\u201d]?\s*[,}]\s*"?(?:tone|act|d|leave|say|reply|intent)?"?\s*[:}].*$|["\u201d]\s*\}.*$', re.S)
_META = re.compile(
    r"\b(\d+\s*words?\s*(max|maximum|or (less|fewer))|word (limit|count)|single (response|reply|line)|one (response|reply|line) only|"
    r"in character|out of character|as an ai|language model|the player|the prompt|(the|my|these|your) instructions (say|are)|json|"
    r"respond(ing)? (as|in)|my (response|reply|answer) (is|should|must|will)|here'?s (my|the) (response|reply|line)|"
    r"(response|reply|output|answer|note|reasoning|thought|analysis)\s*:|let me think|i should (say|respond|reply)|"
    r"\bnpc\b|tone\s*=|act\s*=)", re.I)


def strip_leaks(text):
    text = str(text or "")
    text = _THINK.sub(" ", text)
    if re.search(r"</think>", text, re.I):  # an unclosed block: keep only what follows it
        text = re.split(r"</think>", text, flags=re.I)[-1]
    text = re.sub(r"^\s*<think>.*$", " ", text, flags=re.I | re.S)
    text = _JSON_TAIL.sub("", text)
    text = re.sub(r"^\s*(response|reply|answer|output|line|dialogue|npc)\s*:\s*", "", text, flags=re.I)
    parts = re.split(r"(?<=[.!?])\s+", text.strip())
    kept = [p for p in parts if not _META.search(p)]
    if not kept and parts:
        kept = parts[:1] if not _META.search(parts[0]) else []
    return " ".join(kept).strip()


def clean_reply(text):
    text = strip_leaks(text)
    text = _MARKUP.sub(" ", str(text or ""))  # 0.5.2.3: no \color{..} / <RGB:..> markup in a spoken line
    text = one_line(text)
    text = str(text or "").replace("\r", " ").replace("\n", " ")
    text = re.sub(r"\*(k+s+h+t+|static|crackle)\*", lambda m: "\x00" + m.group(1) + "\x01", text, flags=re.I)
    text = re.sub(r"\*[^*]{0,80}\*", " ", text)
    text = text.replace("\x00", "*").replace("\x01", "*")
    text = re.sub(r"^\s*\([^)]{0,80}\)", " ", text)
    text = re.sub(r"\s+", " ", text).strip().strip('"').strip()
    if BANNED.search(text):
        text = "Don't know what you're getting at."
    sentences = re.split(r"(?<=[.!?])\s+", text)
    text = " ".join(sentences[:3]).strip()
    if len(text) > 200:
        text = text[:197].rsplit(" ", 1)[0] + "..."
    return text


# 0.8.3 step 3: REPLY SUGGESTIONS. With the talk window open the mod sends req.suggest = N (1-3); the model adds
# "suggest": short things the PLAYER could say next. Cleaned here; the mod shows them as rows on the Say tab.
SUGGEST_MAX_CHARS = 60
SUGGEST_TOKENS = 22  # extra reply tokens per suggestion (8 words + JSON quoting)


# 0.8.3 step 4: THEY ASK BACK. req.askBack = 0 off / 1 rarely / 2 sometimes / 3 often; the model sets "ask": true
# when its line is a real question it wants answered. req.answering = {q, ago}: the player's line answers it.
ASKBACK_HOW = {1: "now and then (maybe one line in five)", 2: "sometimes (maybe one line in three)",
               3: "often, when there's anything worth asking"}


def askback_rule(req):
    if req.get("mode") not in (None, "", "reply"):
        return None
    try:
        lvl = int(req.get("askBack") or 0)
    except Exception:
        lvl = 0
    if lvl <= 0:
        return None
    t = ("Like a real person you sometimes ask them something back - about them, where they're headed, what they "
         f"want, a choice you need them to make. Do it {ASKBACK_HOW.get(min(3, lvl), ASKBACK_HOW[2])}, only when it "
         "fits, never just to fill space. ask = true ONLY when your line ends with a question you really want them "
         "to answer; false for rhetorical questions or none.")
    if req.get("suggest"):
        t += " If ask is true, suggest = possible answers they could give to YOUR question."
    return t


def answering_core(req):
    if req.get("mode") not in (None, "", "reply"):
        return None
    a = req.get("answering")
    if not isinstance(a, dict) or not _s(a.get("q")):
        return None
    return (f'You asked them: "{_s(a.get("q"), 200)}". Their line is their answer to that (or them dodging it): react '
            "to what they actually answered, the way you would to that answer. Don't ask the same thing again.")


# 0.8.3 step 5: PACE. req.length = 1 short (default) / 2 normal (the old 25-word rule) / 3 chatty.
LENGTHS = {1: "one or two short sentences, max 15 words - people talk short out here",
           2: "1-2 short sentences, max 25 words",
           3: "up to 3 sentences, max 40 words, if there's really something to tell"}
LENGTH_EXTRA_TOKENS = {3: 30}
CALM_LENGTH = "1-3 short sentences, max 35 words, if the talk is easy and there is something to say"
CALM_EXTRA = {"tokens": 20}  # --calm-extra: extra num_predict in a calm scene at length 2 (0 = off)


def length_level(req):
    try:
        n = int(req.get("length") or 2)
    except Exception:
        n = 2
    return max(1, min(3, n))


def calm_scene(req):
    """PLAN-CONVO P1: no fight, no zombies near = calm camp talk (may run a little longer)."""
    if req.get("mode") not in (None, "", "reply") or length_level(req) < 2:
        return False
    fight = req.get("fight") or {}
    return not (isinstance(fight, dict) and fight) and not ((req.get("world") or {}).get("zombies"))


def reply_length(req):
    if calm_scene(req) and length_level(req) == 2:
        return CALM_LENGTH
    return LENGTHS[length_level(req)]


def suggest_rule(req):
    if req.get("mode") not in (None, "", "reply"):
        return None
    try:
        n = int(req.get("suggest") or 0)
    except Exception:
        n = 0
    if n <= 0:
        return None
    n = min(3, n)
    return (f"suggest = {n} short things THEY (the other person, not you) might say back to your line, in their voice, "
            "first person, max 8 words each, each a different direction (e.g. one warm, one curious, one blunt or "
            "pushy). Plain words, no quotes, no names unless they know them, nothing they couldn't know.")


def clean_suggestions(raw, n=3):
    out, seen = [], set()
    for x in raw if isinstance(raw, list) else []:
        if not isinstance(x, str):
            continue
        t = re.sub(r"\s+", " ", x).strip().strip("\"'“”").strip()
        t = t.replace("|", "/")
        if not t or len(t) > SUGGEST_MAX_CHARS or t.lower() in seen:
            continue
        seen.add(t.lower())
        out.append(t)
        if len(out) >= n:
            break
    return out


def parse_model_output(content, acts):
    content = (content or "").strip()
    data = None
    try:
        data = json.loads(content)
    except Exception:
        m = re.search(r"\{.*\}", content, re.S)
        if m:
            try:
                data = json.loads(m.group(0))
            except Exception:
                data = None
    if not isinstance(data, dict):  # truncated by num_predict: salvage the fields we can
        data = {}
        for k in ("tone", "act"):
            m = re.search(r'"%s"\s*:\s*"([A-Z_]+)"' % k, content)
            if m:
                data[k] = m.group(1)
        m = re.search(r'"d"\s*:\s*(-?\d+)', content)
        if m:
            data["d"] = int(m.group(1))
        m = re.search(r'"say"\s*:\s*"((?:[^"\\]|\\.)*)', content)
        if m:
            raw = m.group(1)
            try:  # 0.5.2.2: real JSON unescape (\u2019, \n ...), not only \"
                data["say"] = json.loads('"' + raw.rstrip("\\") + '"')
            except Exception:
                data["say"] = raw.replace('\\"', '"').replace("\\n", " ")
            if not re.search(r"[.!?]$", data["say"].strip()):
                cut = re.split(r"(?<=[.!?])\s+", data["say"])
                data["say"] = " ".join(cut[:-1]) if len(cut) > 1 else data["say"].rstrip(",; ") + "..."
        elif content and not content.startswith("{"):
            data["say"] = content
    try:
        d = int(round(float(data.get("d", 0))))
    except Exception:
        d = 0
    tone = str(data.get("tone") or "NONE").upper()
    act = str(data.get("act") or "NONE").upper()
    leave = data.get("leave")
    return {
        "tone": tone if tone in TONES else "NONE",
        "act": act if act in acts else "NONE",
        "d": max(-10, min(10, d)),
        "leave": leave is True or str(leave).lower() == "true",
        "say": clean_reply(data.get("say") or data.get("reply") or ""),
        "suggest": clean_suggestions(data.get("suggest")),
        "ask": data.get("ask") is True or str(data.get("ask")).lower() == "true",
        "gesture": str(data.get("gesture") or "").lower() if str(data.get("gesture") or "").lower() in GESTURES else "",
        "cmd": _s(data.get("cmd"), 30),
        "cmdItem": _s(data.get("cmdItem"), 40),
        "want": _s(data.get("want"), 20).lower(),
        "sokind": _s(data.get("sokind"), 20).lower(),
    }


# ---------------------------------------------------------------------------------------------------------------
# v0.3.1 calibration: small models score "how is your day" as a threat and pick random actions. The player's own
# words decide the allowed range for d / tone / act / leave; the model only picks inside that range.
# ---------------------------------------------------------------------------------------------------------------
_YOU = r"\b(you|you'?re|youre|ur|u|ya|your|yourself|y'?all)\b"
_THREAT = re.compile(
    r"\b(i'?ll|i will|i'?m gonna|im gonna|gonna|going to|i'?m going to|i could|i should|i want to|wanna)\s+"
    r"(kill|shoot|stab|murder|hurt|end|gut|beat|cut|strangle|choke|burn|rob|smash|knock|punch|slap|cap|waste|"
    r"rip|break)\s+(you|ya|u|y'?all|your)\b|\b(kill|shoot|stab|murder|gut|strangle)\s+(you|ya|u|y'?all)\b|"
    r"\byou'?re (dead|gonna die|going to die)\b|\b(go die|drop dead|hope you die|or else|or i'?ll)\b|"
    r"\b(this is a (robbery|stick ?up)|hand over (your|everything|all)|give me (all )?your (stuff|bag|gun|loot|money|"
    r"food|things|items|weapon)s?)\b|\bi'?ll (feed you to|leave you for) the (zombies|dead)\b", re.I)
_RUDE_ALWAYS = re.compile(
    r"\b(f+u+c+k+|fuk|fk|screw|damn|to hell with)\s*(you|u|ya|off|yourself|y'?all)\b|\bfuck(ing)? (idiot|moron|loser|"
    r"bitch|asshole|retard)|\b(shut up|shut the fuck up|stfu|piss off|bugger off|eat shit|suck my|kiss my ass|"
    r"go to hell|nobody likes you|no one likes you|i hate you|hate you|you suck|you stink|you smell|get bent|"
    r"up yours|bite me|blow me|what(cha| are you| you| ya)? ?gonna do about it|come at me|bring it on|"
    r"make me|wanna fight|want to fight|square up|you want some)\b|\bsob\b|\bpiece of (shit|crap|garbage|trash)\b", re.I)
_INSULT_WORDS = (r"(idiot|moron|stupid|dumb|dumbass|dumb ?fuck|retard(ed)?|bitch|asshole|bastard|dick|dickhead|prick|cunt|"
                 r"loser|ugly|fatass|pathetic|worthless|useless|coward|clown|jerk|freak|whore|slut|scum|creep|weirdo|"
                 r"imbecile|halfwit|dimwit|twat|wanker|douche(bag)?|pussy|scumbag|crybaby|fool|nitwit|liar|chump|chud|punk|"
                 r"scrub|simp|dork|wimp|sissy|bozo|chode|turd|maggot|dirtbag|lowlife|degenerate|numbnuts|dipshit|"
                 r"shithead|jackass|dumbshit|fucker|motherfucker|mf|son of a bitch|sob|cuck|tool|bum|hobo|rube|"
                 r"piece of (shit|crap|garbage|trash)|waste of (space|air|oxygen)|joke)")
_FILL = r"(?:(?:a|an|such|so|fucking|freaking|damn|little|big|real|really|total|complete|stupid|dumb|lazy|"\
        r"fat|ugly|old|useless|worthless|pathetic|goddamn)\s+)*"
_INSULT_DIRECTED = re.compile(
    r"\b(you|ya|u)\s+(are\s+|r\s+)?" + _FILL + _INSULT_WORDS + r"\b|"
    r"\b(you'?re|youre|ur|u r|you look|you sound|you smell)\s+(like\s+)?" + _FILL + _INSULT_WORDS + r"\b|"
    r"\bwhat an?\s+" + _FILL + _INSULT_WORDS + r"\b", re.I)
_ABOUT_INSULT = re.compile(r"\b" + _INSULT_WORDS + r"\b", re.I)
_INSULT_ALONE = re.compile(r"^\W*(you\s+)?" + _FILL + _INSULT_WORDS + r"\W*$", re.I)
_DISMISS = re.compile(r"\b(go away|get lost|leave me alone|get out of (here|my face|my way)|beat it|scram|buzz off|"
                      r"get away from me|back off|leave now|get outta here|go home)\b", re.I)
_SORRY = re.compile(r"\b(sorry|my bad|apologi[sz]e|forgive me|didn'?t mean (it|that)|i was wrong)\b", re.I)
_THANKS = re.compile(r"\b(thanks|thank you|thank ya|thx|ty|appreciate (it|that|you)|much obliged|cheers)\b", re.I)
_GREET = re.compile(r"^\W*(hi+|hey+|hello+|howdy|yo|hiya|sup|wassup|what'?s up|whats up|good (morning|afternoon|evening)|"
                    r"greetings|heya|evening|morning|afternoon|hola|g'?day)\b", re.I)
_BYE = re.compile(r"\b(bye|goodbye|good bye|see (you|ya)|take care|gotta go|got to go|so long|farewell|good night|"
                  r"catch you later|later then|i'?m off|i'?ll be going|over and out|signing off)\b", re.I)
_FRIENDLY = re.compile(r"\b(i'?m|im|i am)\s+(a\s+|just\s+|really\s+)?(friendly|friend|nice|harmless|no threat|not a threat|"
                       r"not (gonna|going to) hurt|peaceful|good guy|nice guy|one of the good)|\b(we'?re|we are) "
                       r"friends\b|^\W*((hey|hi|hello|howdy|yo)\W+)?(friend|buddy|pal|partner)\b|"
                       r"\bno harm\b|\bin peace\b|\bmean no harm\b|\bnice to meet\b|"
                       r"\bpleasure to meet\b|\bglad (you'?re|to see)\b", re.I)
_HELP = re.compile(r"\b(can i help|need (any |some )?help|i can help|let me help|want (some|any) (food|water|help|meds)|"
                   r"need (anything|something|food|water|meds)|i('ll| will) (help|protect|cover|watch your back)|"
                   r"here,? take|have some|you can have|i got your back|i brought)\b", re.I)
_COMPLIMENT = re.compile(r"\b(you'?re|you are|youre|ur|u r)\s+(so\s+|really\s+|pretty\s+|very\s+)?(awesome|great|cool|nice|"
                         r"kind|smart|brave|amazing|the best|pretty|beautiful|handsome|funny|tough|strong|good|"
                         r"badass|sweet|lovely|clever|wise|hilarious|legend)\b|\b(nice|cool|great|love your|like your) "
                         r"(hat|gun|jacket|shirt|outfit|work|job|shooting|boots|car|bike|beard|hair)\b|"
                         r"\bgood (job|work|shot|shooting|call)\b|\bwell done\b", re.I)
_NEGATED = re.compile(r"\b(not|n'?t|never|no)\s+(an?\s+|so\s+|that\s+|really\s+)?$", re.I)

# v0.3.3: real-game misses ("your moms a whore", "you wanna die bitch", "im glad shes dead", "ill fuck her body",
# "now ur gonna die to", "i just murdered a bitch") - broader cruelty / threat lexicon
_SLUR = re.compile(r"\b(nigg(?:er|a|ah|uh|az)s?|fagg?(?:ot)?s?|tranny|trannies|spics?|chinks?|kikes?|wetbacks?|gooks?|"
                   r"beaners?|towelheads?|ragheads?|dykes?|retards?)\b", re.I)
_VOC_WORDS = (r"(bitch(es)?|whore|slut|cunt|bastard|asshole|motherfucker|fucker|pussy|dickhead|prick|scum|scumbag|maggot|"
              r"loser|idiot|moron|retard|twat|wanker|dipshit|shithead|jackass|hoe|ho|skank|coward)")
_VOCATIVE = re.compile(r"(^|[,!.?]\s*|\s)" + _VOC_WORDS + r"\s*[!.?]*\s*$", re.I)
_FAMILY = (r"(moms?|mother|mama|momma|mum|dad|father|pops|sister|sis|brother|wife|girl|girlfriend|husband|son|daughter|"
           r"kids?|family|friends?|buddy|people|crew|boss|leader|grandma|granny|aunt|cousin|man|woman)")
_FAMILY_INSULT = re.compile(r"\b(your|ur|yo|ya|her|his|their)\s+" + _FAMILY + r"(?:'?s|\s+is|\s+was|\s+a|\s+an|\s)+.{0,30}?\b"
                            + _INSULT_WORDS + r"\b|\byo (mama|momma)\b|\b(your|ur) (moms?|mother|mama|sister|wife|daughter)\b.{0,30}"
                            r"\b(fuck\w*|suck\w*|blow\w*|easy|hoe?|whore|slut|fat|ugly|screw\w*|bang\w*)\b", re.I)
_SEXUAL = re.compile(r"\b(i'?ll|ill|i will|i'?m gonna|im gonna|gonna|i wanna|wanna|i want to|let me|i'?d|id|i)\s+(fuck|rape|screw|"
                     r"bang|hump|molest|grope|fondle|pound|smash|fucked|raped|screwed|banged)\s+(her|him|them|your|ur|his|their|"
                     r"that|its)\b|\b(fuck|fucked|rape|raped|screw|screwed|bang|banged|hump|humped)\s+(her|his|your|ur|their)\s+"
                     r"(dead\s+)?(body|corpse|ass|sister|mom|mother|wife|daughter|girl|kid)\b|\b(rape\w*|necro\w*)\b", re.I)
_GLOAT = re.compile(r"\b(glad|happy|good|great|lol|lmao|haha\w*)\b.{0,25}\b(she|he|they|it|shes|hes|theyre)('?s|'?re| is| are|"
                    r" was| were)?\s+(dead|died|gone|burning|rotting)\b|"
                    r"\b(glad|happy) (she|he|they|it) (died|got killed|got bit\w*|is gone)|"
                    r"\b(she'?s|shes|he'?s|hes|they'?re|theyre)\s+(in hell|burning|rotting|zombie food|worm food|better off dead)\b|"
                    r"\b(burn|rot|roast)(ing|s)? in hell\b|\bin hell burning\b|\bgood riddance\b|\b(deserved it|had it coming|"
                    r"asked for it|deserved to die)\b|"
                    r"\bi (just |already |finally )?(killed|murdered|shot|stabbed|butchered|slaughtered|executed|wasted|smoked|"
                    r"capped|offed|gutted)\s+(a|an|her|him|them|that|your|ur|this|the|some|one|my|his)\b|"
                    r"\b(who'?s next|you'?re next|ur next|youre next|you next)\b|\bone less\b|"
                    r"\b(how'?d that feel|how does that feel|eat that|suck it|cry (about it|more)|get rekt|git gud|stay down)\b", re.I)
_TAUNT_FIGHT = re.compile(r"\b(you like that|like that huh|feel that|want more|had enough|that'?s what you get|take that|"
                          r"come on then|is that all|that all you got|too slow|haha\w*|lol|lmao)\W*$", re.I)
_DEATH_THREAT = re.compile(
    r"\b(you|ya|u|ur|you'?re|youre|y'?all)\s+(wanna|want to|gonna|going to|will|'?ll|are gonna|r gonna|gon|about to|bout to|"
    r"is gonna)\s+(die|be dead|get killed|bleed|regret)\b|"
    r"\b(wanna|want to) die\b|\b(gonna|going to|will|'?ll|about to) die (too|to|next|now|today|tonight|slow|here)\b|"
    r"\bdie,? (bitch|fucker|motherfucker|scum|asshole|now)\b|"
    r"\b(i'?ll|ill|i will|gonna|going to|i'?m gonna|im gonna|let me|i should|i could|i want to|i wanna)\s+(kill|shoot|stab|"
    r"murder|end|gut|cut|strangle|choke|burn|waste|cap|smoke|off|slit|skin|behead|hang|bury)\s+(you|ya|u|y'?all|your|ur|all of "
    r"you|every one of you|her|him|them|everyone|everybody)\b|"
    r"\b(dead man|dead meat|your funeral|say goodbye|say your prayers|count your days|watch your back|sleep with one eye|"
    r"coming for you|i'?m coming for|i'?ll find you|you'?re dead|ur dead|youre dead)\b|"
    r"\b(kill|murder|shoot|stab)\s+(you|ya|u)\s+(too|to|next|all|both|slow|dead)\b", re.I)
_EDGY = re.compile(r"\b(die|dies|died|dead|death|kill\w*|murder\w*|hell|bitch\w*|whore\w*|slut\w*|fuck\w*|shit\w*|cunt|"
                   r"rape\w*|corpse|body|blood\w*|shoot\w*|stab\w*|burn\w*|rot\w*|moms?|mother|mama|sister|wife|daughter|ass|"
                   r"dick|cock|pussy|suck\w*|hate|ugly|fat|stupid|dumb|idiot|moron|loser|weak|coward|pathetic|haha\w*|lol|"
                   r"lmao|whatever|shut|bleed\w*|hurt|gun|knife)\b", re.I)
BAD_TONES = ("INSULT", "THREATEN", "GO_AWAY")

# what the player must literally ask for before an A-Life action may run
ACT_ASKS = {
    "WALK_WITH_ME": r"\b(follow|come with|walk with|tag along|come along|escort|join me|lead the way|show me the way|"
                    r"take me (to|with)|let'?s go|come on|with me|stick with me|stay with me|travel with)\b",
    "WALK_STOP": r"\b(stop following|stop walking|quit following|wait here|stay here|stay put|wait for me|hold up here|"
                 r"you can go|go on without|done walking|go back|go home|split up|leave me|go away|get lost|piss off)\b",
    "PARTY_JOIN": r"\b(join (my|our|us|the) (group|crew|team|party|camp|base)|join us|be (part|one) of (us|my|our)|"
                  r"come live with|recruit|want to join|wanna join|can i join|let me join)\b",
    "PARTY_LEAVE": r"\b(leave (my|our|the) (group|crew|team|party)|kick(ed)? (you )?out|you'?re out of the group|"
                   r"part ways|you'?re fired|not part of)\b",
    "PARTY_TASK_ASK": r"\b(job|task|chore|something to do|anything (i|you) can do|orders|what should (i|we) do|work for)\b",
    "PARTY_TASK_DONE": r"\b(done|finished|completed|did (it|the job|that))\b",
    "PARTY_STORY": r"\b(story|stories|tale|tell me about)\b",
    "ASK_TRADE": r"\b(trade|trading|swap|barter|buy|sell|deal|exchange|what (do|have) you got|wares|goods)\b",
    "ASK_FOOD": r"\b(food|eat|hungry|starving|snack|meal)\b",
    "ASK_WATER": r"\b(water|thirsty|something to drink)\b",
    "ASK_MEDS": r"\b(meds|medicine|medical|bandage|pills|first aid|antibiotic|painkiller|disinfectant|bleeding|wound)\b",
    "ASK_NAME": r"\b(your name|who are you|what'?s your name|whats ur name|whats your name|name\?|introduce)\b",
    "HANDS_UP": r"\b(hands up|put your hands|reach for the sky|hands where i can see)\b",
    "DROP_WEAPON": r"\b(drop (it|the|your|that)|put (it|the gun|the weapon|your weapon|that) down|lower your|disarm)\b",
    "DEMAND_ITEMS": r"\b(give me (your|all|everything)|hand (it )?over|empty your|this is a robbery|stick ?up|"
                    r"your (stuff|bag|loot|money) or)\b",
}


def _insult_hit(low):
    """An insult word aimed at them ("you're an idiot", "what a loser", "idiot!"), not "this gun is useless"."""
    for m in _INSULT_DIRECTED.finditer(low):
        if not _NEGATED.search(low[:m.start()][-20:]) and not re.search(r"\b(not|n'?t|never)\b", m.group(0)):
            return True
    return bool(_INSULT_ALONE.search(low))


def _unnegated(rx, low):
    """A match not preceded by a negation ("i'm NOT gonna hurt you", "i would never kill you")."""
    for m in rx.finditer(low):
        if not re.search(r"\b(not|n'?t|never|no one|nobody|wont|dont|cant|ain'?t)\b[\w' ]{0,12}$", low[:m.start()]):
            return True
    return False


def judge_line(text, a_intent=None, fight=False):
    """How the player's line comes across, from their own words (and A-Life's classifier)."""
    low = " ".join(str(text or "").lower().replace("\u2019", "'").split())
    cruel = bool(_SLUR.search(low) or _FAMILY_INSULT.search(low) or _SEXUAL.search(low) or _GLOAT.search(low))
    j = {"threat": _unnegated(_THREAT, low) or _unnegated(_DEATH_THREAT, low) or a_intent == "THREATEN",
         "rude": bool(_RUDE_ALWAYS.search(low)) or _insult_hit(low) or a_intent == "INSULT" or cruel
         or bool(_VOCATIVE.search(low)) or (fight and bool(_TAUNT_FIGHT.search(low))),
         "cruel": cruel, "edgy": bool(_EDGY.search(low)),
         "dismiss": bool(_DISMISS.search(low)) or a_intent == "GO_AWAY",
         "sorry": bool(_SORRY.search(low)) or a_intent == "SORRY",
         "thanks": bool(_THANKS.search(low)) or a_intent == "THANKS",
         "greet": bool(_GREET.search(low)) or a_intent == "GREETING",
         "bye": bool(_BYE.search(low)) or a_intent == "FAREWELL",
         "friendly": bool(_FRIENDLY.search(low)) or a_intent == "I_AM_FRIENDLY",
         "help": bool(_HELP.search(low)) or a_intent == "OFFER_HELP",
         "compliment": bool(_COMPLIMENT.search(low)) or a_intent == "COMPLIMENT",
         "low": low}
    j["hostile"] = j["threat"] or j["rude"]
    j["kind"] = not j["hostile"] and (j["sorry"] or j["thanks"] or j["friendly"] or j["help"] or j["compliment"])
    return j


def act_allowed(act, said):
    pat = ACT_ASKS.get(act)
    return bool(pat) and re.search(pat, str(said or "").lower().replace("\u2019", "'")) is not None


def calibrate(result, req):
    """Bound the model's d / tone / act / leave by what the player actually said. Returns (result, notes)."""
    if not isinstance(result, dict):
        return result, []
    said = req.get("said") or ""
    fight = req.get("fight") or {}
    fighting = bool(fight.get("hostile") or fight.get("fighting"))
    grieving = bool(req.get("grief"))
    op = (req.get("npc") or {}).get("op")
    tense = fighting or grieving or (isinstance(op, (int, float)) and op <= -40)
    j = judge_line(said, req.get("aIntent"), fighting)
    if fight_vs_dead(req) and j["dismiss"] and not j["threat"] and not j["rude"]:
        j = dict(j, dismiss=False, warn=True)  # 0.8.11.2 (Miller): "get outta here!" mid-fight = a warning
    raw = dict(result)
    d = int(result.get("d") or 0)
    mtone = str(result.get("tone") or "NONE")
    model_bad = d < 0 or mtone in BAD_TONES
    # v0.3.3: "clearly benign" = no hostile cue in the words at all (no edgy vocabulary). Only then is a negative
    # model score clamped away (small models call "how is your day" a threat). Otherwise a negative score that
    # matches a hostile tone is trusted.
    benign = (not j["hostile"] and not j["edgy"] and not j["dismiss"]) or (j.get("warn") and not j["hostile"])
    if j["threat"]:
        tone = "THREATEN"
        d = max(-10, min(d, -6 if (j["cruel"] or tense) else -4))
    elif j["rude"]:
        tone = "INSULT"
        if j["cruel"]:
            d = max(-10, min(d, -6))      # slurs, mocking the dead, gloating, sexual remarks, "your mom"
        else:
            d = (-4 if tense else -3) if d >= 0 else max(-8, min(d, -1))
    elif j["dismiss"]:
        tone = "GO_AWAY"
        d = -1 if d >= 0 else max(-3, d)
    elif not benign and not j["kind"] and model_bad:
        # edgy words the lexicon can't place: trust the model's negative call (bounded)
        if mtone in BAD_TONES or tense:
            tone = mtone if mtone in BAD_TONES else ("INSULT" if d <= -3 else "NONE")
            d = max(-8, min(d, -1)) if d < 0 else (-3 if tense else -2)
        else:  # negative score without a hostile tone in a calm moment: barely counts
            tone, d = "NONE", max(-1, min(d, 0))
    else:
        if j["sorry"]:
            tone = "SORRY"
        elif j["thanks"]:
            tone = "THANKS"
        elif j["help"]:
            tone = "OFFER_HELP"
        elif j["compliment"]:
            tone = "COMPLIMENT"
        elif j["friendly"]:
            tone = "I_AM_FRIENDLY"
        elif j["bye"]:
            tone = "FAREWELL"
        elif j["greet"]:
            tone = "GREETING"
        else:
            tone = "NONE"
        if j["kind"]:
            lift = 1 if (j["thanks"] or j["help"] or j["compliment"]) else 0
            d = lift if d <= 0 else min(d, 7 if j["help"] else 4)
        else:
            d = max(0, min(d, 2))  # ordinary chat / questions / greetings: never negative
    act = result.get("act") or "NONE"
    if act != "NONE" and not act_allowed(act, said):
        act = "NONE"
    # after an insult/threat only the player's own demands (hands up / drop it / give me your stuff) may run;
    # never "walk with me" or a request/favour
    if j["hostile"] and act not in ("NONE", "HANDS_UP", "DROP_WEAPON", "DEMAND_ITEMS"):
        act = "NONE"
    leave = bool(result.get("leave"))
    if leave and not (j["hostile"] or j["dismiss"] or j["bye"] or (isinstance(op, (int, float)) and op <= -40)):
        leave = False
    out = dict(result, d=d, tone=tone, act=act, leave=leave)
    notes = [f"{k} {raw.get(k)}->{out.get(k)}" for k in ("d", "tone", "act", "leave") if raw.get(k) != out.get(k)]
    return out, notes


def ollama_error_kind(e, model, url=""):
    """0.8.11.2: a refused connection (Ollama not running) reads differently from a timeout (Ollama up, model slow:
    still loading, or too big for the graphics card and spilling to the CPU)."""
    txt = str(e)
    low = txt.lower()
    inner = getattr(e, "reason", None)
    if isinstance(e, ConnectionRefusedError) or isinstance(inner, ConnectionRefusedError) or "refused" in low \
            or "10061" in low:
        return f"Ollama not running at {url or 'its address'} (connection refused)"
    if isinstance(e, (socket.timeout, TimeoutError)) or isinstance(inner, (socket.timeout, TimeoutError)) \
            or "timed out" in low:
        return (f"Ollama is running but model {model} did not answer in time (still loading, or too big for your "
                f"video memory - check 'ollama ps': a CPU/GPU split means it spills to the CPU): {txt}")
    if isinstance(e, urllib.error.HTTPError):
        return f"Ollama answered HTTP {e.code} for model {model}: {txt}"
    return f"{type(e).__name__} with model {model}: {txt}"


class DeadlineExceeded(Exception):
    pass


class OllamaBusy(Exception):
    pass


class Ollama:
    def __init__(self, args):
        self.a = args
        self.schema_ok = True
        self.recovering = False
        self.down_until = 0
        self.job_end = None
        self.job_mode = "reply"

    def options(self):
        # v0.4.0: repeat_penalty 1.15 over the last 128 tokens (anti-repeat, on top of the recent-lines check)
        # v0.5.1: min_p + top_k (Stheno-friendly), gentler repeat_penalty (variety comes from the prompt now)
        o = {"temperature": self.a.temperature, "num_predict": self.a.num_predict, "num_ctx": self.a.num_ctx,
             "top_p": getattr(self.a, "top_p", 0.9), "repeat_penalty": getattr(self.a, "repeat_penalty", 1.1),
             "repeat_last_n": getattr(self.a, "repeat_last_n", 128)}
        if getattr(self.a, "min_p", 0):
            o["min_p"] = self.a.min_p
        if getattr(self.a, "top_k", 0):
            o["top_k"] = self.a.top_k
        if getattr(self, "_mode", None) in CHATTER_MODES and getattr(self.a, "chatter_temperature", 0):
            o["temperature"] = self.a.chatter_temperature
        extra = int(getattr(self, "_extra_predict", 0) or 0)
        if extra > 0:  # 0.8.3 step 3: room for the suggestions so the reply itself is never cut short
            o["num_predict"] = int(o["num_predict"]) + extra
        return o

    def model_for(self, mode):
        """v0.4.0: background work (ambient, overheard, reactions, summaries, backstories, radio bulletins) can use a second model.
        v0.5.0: --dialogue-model (e.g. an RP fine-tune like L3-8B-Stheno) answers the player directly."""
        bg = getattr(self.a, "background_model", None) or self.a.model
        if mode in (None, "", "reply", "radio", "gift"):
            return getattr(self.a, "dialogue_model", None) or self.a.model
        return bg

    def options_for(self, model):
        """v0.5.0 --bg-on-cpu: the background model runs on the CPU (num_gpu 0) so both fit next to the game in VRAM."""
        o = self.options()
        if getattr(self.a, "bg_on_cpu", False) and getattr(self.a, "background_model", None) and model == self.a.background_model \
                and model != self.model_for("reply"):
            o["num_gpu"] = 0
        return o

    def post(self, path, body, timeout):
        req = urllib.request.Request(self.a.ollama.rstrip("/") + path, data=json.dumps(body).encode("utf-8"),
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read().decode("utf-8"))

    # v0.4.2: hard per-request deadlines (seconds). A hung Ollama generation can no longer hold the bridge: past the
    # deadline the socket is shut down from another thread (Ollama sees the client leave and drops the job) and a
    # health check runs in the background.
    DEADLINES = {"reply": 25, "radio": 25, "gift": 25, "story": 12, "summary": 20, "bulletin": 25}
    BG_DEADLINE = 12

    def deadline_for(self, mode):
        over = getattr(self.a, "deadlines", None) or {}
        mode = mode or "reply"
        return float(over.get(mode) or self.DEADLINES.get(mode) or over.get("bg") or self.BG_DEADLINE)

    def begin(self, mode):
        """One job (all its model calls, retries included) gets one deadline."""
        self.job_mode = mode or "reply"
        self.job_end = time.time() + self.deadline_for(mode)

    def stream(self, body, should_abort, deadline=None):
        """Streamed /api/chat; returns the final chunk with the full content, or None if aborted.
        The HTTP exchange always runs on a worker thread; this thread watches should_abort (every 50 ms) and the
        deadline. On abort / deadline the socket is shut down from a third thread (never blocks), so Ollama drops
        the request instead of finishing it in the background and blocking the next one (OLLAMA_NUM_PARALLEL=1)."""
        if getattr(self, "recovering", False):
            raise OllamaBusy("Ollama is being restarted after a hang")
        if time.time() < getattr(self, "down_until", 0):
            raise OllamaBusy("Ollama did not answer the last health check")
        if deadline is None:
            end = getattr(self, "job_end", None)
            deadline = max(1.0, end - time.time()) if end else self.deadline_for(None)
        u = urllib.parse.urlsplit(self.a.ollama.rstrip("/") + "/api/chat")
        data = json.dumps(body).encode("utf-8")
        box = {"parts": [], "final": None, "err": None, "conn": None}

        def work():
            conn = None
            try:
                cls = http.client.HTTPSConnection if u.scheme == "https" else http.client.HTTPConnection
                conn = cls(u.hostname, u.port or (443 if u.scheme == "https" else 80),
                           timeout=min(float(self.a.timeout), deadline + 2))
                box["conn"] = conn
                conn.connect()
                box["sock"] = conn.sock  # kept: http.client drops conn.sock once the response owns the socket
                conn.request("POST", u.path, body=data, headers={"Content-Type": "application/json"})
                r = conn.getresponse()
                if r.status >= 400:
                    raise urllib.error.HTTPError(self.a.ollama, r.status, r.reason, r.headers, None)
                while True:
                    raw = r.readline()
                    if not raw:
                        break
                    raw = raw.strip()
                    if not raw:
                        continue
                    chunk = json.loads(raw.decode("utf-8"))
                    box["parts"].append(((chunk.get("message") or {}).get("content")) or "")
                    if chunk.get("done"):
                        box["final"] = chunk
                        break
            except Exception as e:  # noqa
                box["err"] = e
            finally:
                try:
                    if conn is not None:
                        conn.close()  # 0.4.1 left the socket open on a timeout: Ollama kept the hung job running
                except Exception:
                    pass

        def kill():
            conn, sock = box["conn"], box.get("sock")
            try:
                if sock is None and conn is not None:
                    sock = conn.sock
                if sock is not None:
                    sock.shutdown(socket.SHUT_RDWR)  # unblocks the worker's read; Ollama drops the request
                    sock.close()
            except Exception:
                pass
            try:
                if conn is not None:
                    conn.close()
            except Exception:
                pass
        t0 = time.time()
        th = threading.Thread(target=work, daemon=True)
        th.start()
        while th.is_alive():
            th.join(0.05)
            if not th.is_alive():
                break
            if should_abort is not None and should_abort():
                threading.Thread(target=kill, daemon=True).start()  # never block the reply path on a close
                return None
            if time.time() - t0 > deadline:
                threading.Thread(target=kill, daemon=True).start()
                self.note_timeout(getattr(self, "job_mode", "?"), deadline)
                raise DeadlineExceeded(f"no answer from Ollama in {deadline:.0f} s (request cancelled)")
        if box["err"] is not None:
            if isinstance(box["err"], (socket.timeout, TimeoutError)):
                self.note_timeout(getattr(self, "job_mode", "?"), deadline)
            raise box["err"]
        text = "".join(box["parts"])
        if box["final"] is not None:
            box["final"]["message"] = {"role": "assistant", "content": text}
            return box["final"]
        return {"message": {"role": "assistant", "content": text}}

    # ---- v0.4.2 health check + recovery (runs on its own thread; the bridge keeps answering / failing fast) ----
    def note_timeout(self, what, deadline):
        self.timeouts = getattr(self, "timeouts", 0) + 1
        th = getattr(self, "health_thread", None)
        if th is not None and th.is_alive():
            return
        self.health_thread = threading.Thread(target=self.check_health, args=(what, deadline), daemon=True)
        self.health_thread.start()

    def loaded_models(self):
        with urllib.request.urlopen(self.a.ollama.rstrip("/") + "/api/ps", timeout=3) as r:
            return [m.get("name") or m.get("model") for m in json.loads(r.read().decode("utf-8")).get("models", [])]

    def probe(self, timeout=10):
        """/api/ps ping + a one-token generation with the same options (so nothing reloads). (ok, info)"""
        t = time.time()
        try:
            loaded = self.loaded_models()
        except Exception as e:
            return False, f"/api/ps failed: {e}"
        body = {"model": self.a.model, "prompt": "ok", "stream": False, "keep_alive": self.a.keep_alive,
                "options": dict(self.options(), num_predict=1)}
        try:
            self.post("/api/generate", body, timeout)
        except Exception as e:
            return False, f"test generation failed after {time.time() - t:.1f} s: {e} (loaded: {', '.join(loaded) or 'none'})"
        return True, f"test generation {1000 * (time.time() - t):.0f} ms, loaded: {', '.join(loaded) or 'none'}"

    def check_health(self, what, deadline):
        ok, info = self.probe(getattr(self.a, "probe_timeout", 10))
        if ok:
            self.down_until = 0
            log(f"  health check after the {what} timeout ({deadline:.0f} s): Ollama is fine ({info}) - it was only slow")
            return
        log(f"!! Ollama looks stuck after the {what} timeout ({info}). RECOVERING: unloading the model(s) and loading "
            "again; player lines get A-Life's own answers meanwhile.")
        self.recovering = True
        t = time.time()
        try:
            names = []
            try:
                names = self.loaded_models()
            except Exception:
                pass
            bg = getattr(self.a, "background_model", None)
            for m in dict.fromkeys([n for n in names + [self.a.model, bg] if n]):
                try:
                    self.post("/api/generate", {"model": m, "keep_alive": 0}, 10)  # keep_alive 0 = unload now
                    log(f"   unloaded {m}")
                except Exception as e:
                    log(f"   unload {m} failed: {e}")
            time.sleep(getattr(self.a, "recover_pause", 1.0))
            try:
                self.preload(timeout=getattr(self.a, "reload_timeout", 120))
            except Exception as e:
                log(f"   reload failed: {e}")
            ok2, info2 = self.probe(getattr(self.a, "probe_timeout", 10))
        finally:
            self.recovering = False
        if ok2:
            self.down_until = 0
            log(f"!! Ollama RECOVERED in {time.time() - t:.1f} s ({info2}). AI replies are back.")
        else:
            self.down_until = time.time() + 20
            log(f"!! Ollama is still not answering after the restart attempt ({info2}). The game uses A-Life's own lines; "
                "the next request in 20 s tries again. If this keeps happening, restart Ollama (ollama serve).")

    def ctx_fallback(self, err):
        """0.5.2.8 [pt265u]: num_ctx 4096 is the default now (2048 cut the prompt). If Ollama can't run it (out of memory,
        HTTP 500), drop to 2048 once and say so. Only when --num-ctx was NOT given."""
        if not getattr(self.a, "ctx_auto", False) or int(getattr(self.a, "num_ctx", 0) or 0) <= 2048:
            return False
        self.a.num_ctx = 2048
        self.a.ctx_auto = False
        log(f"!! Ollama failed with num_ctx 4096 ({err}); using num_ctx 2048 now. Long scenes get trimmed then - "
            "free some VRAM (or set OLLAMA_FLASH_ATTENTION=1 / OLLAMA_KV_CACHE_TYPE=q8_0) and start with --num-ctx 4096.")
        return True

    def chat(self, messages, acts, should_abort=None, model=None):
        body = {"model": model or self.a.model, "messages": messages, "stream": True, "keep_alive": self.a.keep_alive,
                "options": self.options_for(model or self.a.model), "format": schema(acts) if self.schema_ok else "json"}
        try:
            return self.stream(body, should_abort)
        except urllib.error.HTTPError as e:
            if e.code == 400 and self.schema_ok:  # older Ollama without JSON-schema output
                self.schema_ok = False
                body["format"] = "json"
                return self.stream(body, should_abort)
            if e.code >= 500 and self.ctx_fallback(f"HTTP {e.code}"):
                body["options"] = self.options_for(model or self.a.model)
                return self.stream(body, should_abort)
            raise

    def summarize(self, messages, should_abort):
        """Background memory summary; same model and num_ctx so Ollama never reloads."""
        body = {"model": self.model_for("summary"), "messages": messages, "stream": True, "keep_alive": self.a.keep_alive,
                "options": dict(self.options_for(self.model_for("summary")), num_predict=200, temperature=0.3),
                "format": SUMMARY_SCHEMA if self.schema_ok else "json"}
        self.begin("summary")
        out = self.stream(body, should_abort, self.deadline_for("summary"))
        return None if out is None else ((out.get("message") or {}).get("content") or "")

    def preload(self, timeout=None):
        """Load the model into VRAM now (same options as real requests so Ollama does not reload later)."""
        t = time.time()
        msgs = [{"role": "system", "content": build_system({"npc": {"name": "Sam"}})},
                {"role": "user", "content": "hey"}]
        body = {"model": self.model_for("reply"), "messages": msgs, "stream": False, "keep_alive": self.a.keep_alive,
                "options": dict(self.options(), num_predict=1)}
        try:
            self.post("/api/chat", body, timeout or max(self.a.timeout, 300))
        except urllib.error.HTTPError as e:
            if not (e.code >= 500 and self.ctx_fallback(f"HTTP {e.code} while loading")):
                raise
            body["options"] = dict(self.options(), num_predict=1)
            self.post("/api/chat", body, timeout or max(self.a.timeout, 300))
        return time.time() - t


# ---------------------------------------------------------------------------------------------------------------
# 0.5.1 CLOUD AI: any OpenAI-compatible endpoint (OpenRouter, OpenAI, Groq, DeepSeek, Mistral, LM Studio, ...).
# Turned on by <Zomboid>/Lua/alifeai_cloud.txt (enabled=true + url + key + model). Kept out of the mod folder so a
# Workshop update never overwrites it and the key is never shipped with the mod. The key is never logged.
# ---------------------------------------------------------------------------------------------------------------
CLOUD_FILE = "alifeai_cloud.txt"
CLOUD_STATUS = "alifeai_cloud_status.txt"
CLOUD_PLAYER_MODES = (None, "", "reply", "radio", "gift", "thought")
REFUSAL = re.compile(r"\b(i can(?:no|')t (?:help|assist|continue|comply|do that|write|engage)|i'?m not able to (?:help|continue)"
                     r"|i won'?t (?:help|continue|write)|content polic|against (?:my|the) (?:guidelines|policy))", re.I)


def load_cloud(lua_dir):
    """{} when cloud is off / not set up; otherwise url, key, model, background, max_per_hour, profile."""
    path = os.path.join(lua_dir, CLOUD_FILE)
    cfg = {}
    try:
        with open(path, encoding="utf-8-sig") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, _, v = line.partition("=")
                cfg[k.strip().lower()] = v.strip()
    except OSError:
        return {}
    if cfg.get("enabled", "false").lower() not in ("true", "yes", "1", "on") or not cfg.get("key") or not cfg.get("url") \
            or not cfg.get("model"):
        return {}
    try:
        cap = int(cfg.get("max_per_hour", "150"))
    except ValueError:
        cap = 150
    return {"url": cfg["url"].rstrip("/"), "key": cfg["key"], "model": cfg["model"],
            "background": cfg.get("background", "off").lower(), "max_per_hour": max(1, cap),
            "profile": cfg.get("profile", "full").lower()}


class CloudLLM(Ollama):
    """Same interface as Ollama (stream/chat/summarize/preload), talking to /chat/completions instead."""

    def __init__(self, args, cloud):
        super().__init__(args)
        self.c = cloud
        self.rf_level = 2          # 2 = json_schema, 1 = json_object, 0 = no response_format
        self.hour, self.used = -1, 0
        self.state = "starting"
        self.status_path = os.path.join(args.dir, CLOUD_STATUS)

    def set_state(self, state, msg=""):
        if state == self.state and not msg:
            return
        self.state = state
        try:
            write_atomic(self.status_path, f"t={int(time.time() * 1000)}\nstate={state}\nmsg={msg}\n")
        except Exception:
            pass
        if state != "ok":
            log(f"!! cloud AI: {state}" + (f" ({msg})" if msg else ""))

    def model_for(self, mode):
        return self.c["model"]

    def options_for(self, model):
        return self.options()

    def _budget(self):
        """max_per_hour is shared by both bridges (this one and the PowerShell one) through alifeai_cloud_usage.txt."""
        h = int(time.time() // 3600)
        path = os.path.join(self.a.dir, "alifeai_cloud_usage.txt")
        used = 0
        try:
            with open(path, encoding="utf-8") as f:
                kv = dict(l.strip().split("=", 1) for l in f if "=" in l)
            if int(kv.get("hour", -1)) == h:
                used = int(kv.get("used", 0))
        except (OSError, ValueError):
            used = self.used if self.hour == h else 0
        if h != self.hour:
            self.hour = h
            if self.state == "cap":
                self.set_state("ok")
        if used >= self.c["max_per_hour"]:
            self.set_state("cap", f"{self.c['max_per_hour']} requests this hour")
            raise OllamaBusy("cloud hourly cap reached")
        self.used = used + 1
        try:
            write_atomic(path, f"hour={h}\nused={self.used}\n")
        except Exception:
            pass

    def _body(self, body):
        """Ollama-style body -> OpenAI chat body."""
        o = body.get("options") or {}
        msgs = body.get("messages")
        if not msgs and body.get("prompt"):
            msgs = [{"role": "user", "content": body["prompt"]}]
        out = {"model": self.c["model"], "messages": msgs or [], "stream": False,
               "temperature": float(o.get("temperature", getattr(self.a, "temperature", 0.7))),
               "top_p": float(o.get("top_p", 0.9)),
               "max_tokens": max(int(o.get("num_predict", getattr(self.a, "num_predict", 80))) * 2, 120)}
        fmt = body.get("format")
        if fmt is not None and self.rf_level == 2 and isinstance(fmt, dict):
            out["response_format"] = {"type": "json_schema", "json_schema": {"name": "reply", "schema": fmt, "strict": False}}
        elif fmt is not None and self.rf_level >= 1:
            out["response_format"] = {"type": "json_object"}
        return out

    def _post(self, body, timeout, should_abort=None, deadline=None):
        """POST /chat/completions on a worker thread; abort / deadline close the socket. Returns the reply text."""
        u = urllib.parse.urlsplit(self.c["url"] + "/chat/completions")
        data = json.dumps(body).encode("utf-8")
        box = {"text": None, "err": None, "code": None, "conn": None}
        headers = {"Content-Type": "application/json", "Authorization": "Bearer " + self.c["key"],
                   "HTTP-Referer": "https://steamcommunity.com/sharedfiles/filedetails/?id=3827364142",
                   "X-Title": "A-Life NPC Overhaul"}

        def work():
            conn = None
            try:
                cls = http.client.HTTPSConnection if u.scheme == "https" else http.client.HTTPConnection
                conn = cls(u.hostname, u.port or (443 if u.scheme == "https" else 80), timeout=timeout)
                box["conn"] = conn
                path = u.path + (("?" + u.query) if u.query else "")
                conn.request("POST", path, body=data, headers=headers)
                r = conn.getresponse()
                raw = r.read().decode("utf-8", "replace")
                box["code"] = r.status
                if r.status >= 400:
                    box["err"] = raw[:300]
                    return
                j = json.loads(raw)
                ch = (j.get("choices") or [{}])[0]
                box["text"] = ((ch.get("message") or {}).get("content")) or ""
            except Exception as e:  # noqa
                box["err"] = e
            finally:
                try:
                    if conn is not None:
                        conn.close()
                except Exception:
                    pass
        t0 = time.time()
        th = threading.Thread(target=work, daemon=True)
        th.start()
        while th.is_alive():
            th.join(0.05)
            if not th.is_alive():
                break
            if should_abort is not None and should_abort():
                c = box.get("conn")
                threading.Thread(target=lambda: c and c.close(), daemon=True).start()
                return None
            if deadline is not None and time.time() - t0 > deadline:
                c = box.get("conn")
                threading.Thread(target=lambda: c and c.close(), daemon=True).start()
                raise DeadlineExceeded(f"no answer from the cloud AI in {deadline:.0f} s")
        code, err = box["code"], box["err"]
        if code is not None and code >= 400:
            return ("http", code, err)
        if err is not None:
            self.set_state("unreachable", str(err)[:120])
            raise OllamaBusy(f"cloud AI unreachable: {err}")
        return box["text"]

    def stream(self, body, should_abort, deadline=None):
        mode = getattr(self, "job_mode", "reply")
        if self.c["background"] != "cloud" and mode not in CLOUD_PLAYER_MODES:
            raise OllamaBusy("background work is off for the cloud AI (background=off in alifeai_cloud.txt)")
        if deadline is None:
            end = getattr(self, "job_end", None)
            deadline = max(1.0, end - time.time()) if end else self.deadline_for(None)
        self._budget()
        ob = self._body(body)
        while True:
            res = self._post(ob, min(float(self.a.timeout), deadline + 2), should_abort, deadline)
            if res is None:
                return None
            if isinstance(res, tuple):
                _, code, err = res
                low = (err or "").lower()
                if code == 400 and "response_format" in ob and ("response_format" in low or "json" in low or "schema" in low
                                                               or self.rf_level > 0):
                    self.rf_level -= 1
                    log(f"  cloud model refused response_format; trying {'json_object' if self.rf_level == 1 else 'plain text'}")
                    ob = self._body(body)
                    continue
                if code in (401, 403):
                    self.set_state("badkey", "the key was rejected")
                elif code == 402:
                    self.set_state("credits", "out of credits")
                elif code == 404:
                    self.set_state("nomodel", f"model '{self.c['model']}' not found")
                elif code == 429:
                    self.set_state("ratelimit", "the provider is rate-limiting you")
                else:
                    self.set_state("error", f"HTTP {code}")
                raise OllamaBusy(f"cloud AI HTTP {code}: {(err or '')[:160]}")
            if self.state != "ok":
                self.set_state("ok")
            text = res or ""
            if REFUSAL.search(text) and '"say"' not in text[:400]:
                log("  (cloud model refused; using A-Life's own line)")
                text = ""
            return {"message": {"role": "assistant", "content": text}, "done": True}

    def chat(self, messages, acts, should_abort=None, model=None):
        body = {"messages": messages, "options": self.options(), "format": schema(acts)}
        return self.stream(body, should_abort)

    def summarize(self, messages, should_abort):
        self.begin("summary")
        out = self.stream({"messages": messages, "options": dict(self.options(), num_predict=200, temperature=0.3),
                           "format": SUMMARY_SCHEMA}, should_abort, self.deadline_for("summary"))
        return None if out is None else ((out.get("message") or {}).get("content") or "")

    def preload(self, timeout=None):
        """No model to load: one tiny request checks the URL, key and model (shows up as 'AI connected' in game)."""
        t = time.time()
        self.begin("reply")
        self.stream({"messages": [{"role": "user", "content": "Reply with the word ok."}],
                     "options": dict(self.options(), num_predict=5)}, None, 20)
        return time.time() - t

    def note_timeout(self, what, deadline):
        self.timeouts = getattr(self, "timeouts", 0) + 1
        log(f"  cloud AI slow: no answer for the {what} in {deadline:.0f} s (A-Life's own line used)")

    def probe(self, timeout=10):
        return True, "cloud"


def write_atomic(path, text):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    for _ in range(40):
        try:
            os.replace(tmp, path)
            return
        except PermissionError:  # game may be reading it on Windows
            time.sleep(0.01)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


def format_reply_file(req_id, r, ms):
    one = lambda s: str(s).replace("\r", " ").replace("\n", " ")
    return (f"id={one(req_id)}\nd={int(r['d'])}\ntone={one(r['tone'])}\nact={one(r['act'])}\n"
            f"leave={'true' if r['leave'] else 'false'}\nms={int(ms)}\n"
            + (f"pair={one(r['pair'])}\npd={int(r.get('pd') or 0)}\n" if r.get("pair") else "")
            + (f"suggest={one('|'.join(r['suggest']))}\n" if r.get("suggest") else "")  # 0.8.3 step 3
            + ("ask=true\n" if r.get("ask") and not r.get("leave") else "")  # 0.8.3 step 4 (never while leaving)
            + (f"gesture={one(r['gesture'])}\n" if r.get("gesture") in GESTURES and r.get("gesture") != "neutral" else "")
            + (f"cmd={one(r['cmd'])}\n" if r.get("cmd") else "")
            + (f"cmdItem={one(r['cmdItem'])}\n" if r.get("cmd") and r.get("cmdItem") else "")
            + (f"want={one(r['want'])}\n" if r.get("want") and not r.get("leave") else "")  # 0.8.3 step 10
            + (f"sokind={one(r['sokind'])}\n" if r.get("sokind") else "")  # 0.8.5
            + f"text={one(r['say'])}\n")


# v0.3.3 anti-repeat + empty-reply retry
RECENT = {}          # npc uid -> last spoken lines (this bridge session)
RECENT_KEEP = 3
_REFUSAL = re.compile(r"^\W*(i can'?t|i cannot|i won'?t|i'?m (not able|unable|sorry,? but)|sorry,? (but )?i (can'?t|cannot))"
                      r".{0,40}\b(help|assist|fulfil+|engage|create|provide|continue|comply|respond|do that|with that|"
                      r"request|conversation|content)\b", re.I)
FALLBACK_LINES = {
    "threat": ["Try it.", "You first.", "Big words.", "Come on, then.", "Not today."],
    "insult": ["Watch your mouth.", "Say that again.", "Real tough, huh?", "Keep talking.", "You'll regret that."],
    "fight": ["Back off!", "Stay down!", "Not now!", "Move!", "Get out of here!"],
    # 0.8.11.2 (Lava): no bare "What?" - it read as the NPC not wanting to talk; the log says why the stock line ran
    "plain": ["Hm. Say that again?", "Not sure I follow.", "Go on...", "Huh. Okay.", "Come again?", "Right... and?",
              "Mm. Keep talking.", "Sorry, lost you there."],
}


def _norm(t):
    return re.sub(r"[^a-z0-9 ]+", "", str(t or "").lower()).strip()


def recent_for(req):
    uid = str(req.get("uid") or (req.get("npc") or {}).get("name") or "")
    lines = [x for x in (req.get("lastReplies") or []) if isinstance(x, str) and x.strip()]
    for x in RECENT.get(uid, []):
        if x not in lines:
            lines.append(x)
    return uid, lines[-RECENT_KEEP:]


def is_repeat(say, recent):
    n = _norm(say)
    if not n:
        return False
    for r in recent:
        m = _norm(r)
        if not m:
            continue
        if n == m or difflib.SequenceMatcher(None, n, m).ratio() >= 0.85:
            return True
    return False


def catchphrase_of(req):
    """0.5.2.3: the NPC's catchphrase from the persona line ('Catchphrase "Say no more." - use it rarely')."""
    pz = req.get("persona") if isinstance(req.get("persona"), dict) else {}
    m = re.search(r'(?:Catchphrase|Says)\s+"([^"]{2,60})"', str(pz.get("line") or ""))
    return m.group(1).strip().rstrip(".!?,") if m else None


def limit_catchphrase(say, phrase, recent):
    """0.5.2.3: small models put the catchphrase in nearly every line (video 1025: "Say no more", "Mother of
    pearl"). If it was already in one of the NPC's last 3 lines, it is cut from this one."""
    if not say or not phrase:
        return say
    key = _norm(phrase)
    if not key or key not in _norm(say) or not any(key in _norm(r) for r in (recent or [])[-3:]):
        return say
    out = re.sub(re.escape(phrase) + r"[.!?,;]*", " ", say, flags=re.I)
    out = re.sub(r"\s+([,.!?;])", r"\1", out)
    out = re.sub(r",\s*([.!?])", r"\1", out)
    out = re.sub(r"\s+", " ", out).strip(" ,;-")
    if out and not re.search(r"[.!?]$", out):
        out += "."
    if len(_norm(out)) < 4:
        return say
    return out[0].upper() + out[1:]


def remember_said(uid, say):
    if uid and say:
        lst = RECENT.setdefault(uid, [])
        lst.append(say)
        del lst[:-RECENT_KEEP]


def must_line(req, recent):
    mode = req.get("mode")
    rc = req.get("react") if isinstance(req.get("react"), dict) else {}
    if isinstance(rc.get("fallback"), str) and rc["fallback"].strip() and not is_repeat(rc["fallback"], recent):
        return _s(rc["fallback"], 160)  # v0.5.1: the game's own line for this exact moment (e.g. the exact wound)
    kind = (req.get("psyche") or {}).get("kind") if isinstance(req.get("psyche"), dict) else None
    pool = (MUST_LINES_DARK.get(mode) if kind == "dark" else None) or MUST_LINES.get(mode) or ["..."]
    start = int(time.time()) % len(pool)
    for line in pool[start:] + pool[:start]:
        if not is_repeat(line, recent):
            return line
    return pool[0]


def fallback_line(req, recent):
    j = judge_line(req.get("said"), req.get("aIntent"))
    fight = req.get("fight") or {}
    pool = FALLBACK_LINES["threat" if j["threat"] else "insult" if j["rude"] else
                          "fight" if (fight.get("hostile") or fight.get("fighting")) else "plain"]
    for line in pool[int(time.time()) % len(pool):] + pool:
        if not is_repeat(line, recent):
            return line
    return pool[0]


# ---------------------------------------------------------------- v0.4.0: radio news + backstories
NEWS_SCHEMA = {"type": "object", "properties": {"say": {"type": "string"}}, "required": ["say"]}
STORY_SCHEMA = {"type": "object", "properties": {"before": {"type": "string"}, "lost": {"type": "string"},
                                                 "survived": {"type": "string"}, "secret": {"type": "string"}},
                "required": ["before", "lost", "survived", "secret"]}
PUSH = "alifetalk_push.txt"
PUSH_LINES = []
PUSH_SEQ = [int(time.time()) % 100000 * 10]


def push(path, kind, uid, fields):
    """Bridge -> game messages that are not replies (backstories). The game polls this small file every few seconds."""
    one = lambda x: str(x or "").replace("\n", " ").replace("|", "/").strip()
    PUSH_SEQ[0] += 1
    PUSH_LINES.append(f"{PUSH_SEQ[0]}|{one(kind)}|{one(uid)}|" + "||".join(one(f) for f in fields))
    del PUSH_LINES[:-40]
    write_atomic(path, "\n".join(PUSH_LINES) + "\n")


def news_bulletin(req, args, ollama, should_abort=None):
    """Knox County Radio bulletin written from real in-game events (deaths, fights, fires, hordes, rumours)."""
    news = req.get("bulletin") or {}
    events = [e for e in (news.get("events") or []) if isinstance(e, str) and e.strip()][:8]
    if not events:
        return ""
    w = req.get("world") or {}
    station = _s(news.get("station"), 40) or "Knox County Radio"
    kinds = news.get("kinds") if isinstance(news.get("kinds"), list) else []
    tagged = [(f"[{_s(kinds[i], 12)}] " if i < len(kinds) and kinds[i] else "") + _s(e, 160) for i, e in enumerate(events)]
    prompt = (STATIC_HEAD + f"\nYou are Marty, the tired, steady voice of {station} on 99.6 FM, reading the survivor "
              f"bulletin, day {int(w.get('day') or 0)} of the outbreak. Read 3-5 short sentences, max 90 words, from ONLY "
              "these reports. Faction news first ([politics]: wars, truces, new leaders), then grudges and manhunts "
              "([nemesis]), then deaths and danger. Rumour-style, no invented places or names beyond those given, "
              "never address the listener by name: \n- " + "\n- ".join(tagged)
              + "\nEnd with a short survival tip. Plain 1993 radio speech. JSON: {\"say\": \"...\"}")
    if args.echo:
        return f"{station}: " + " ".join(_s(e, 80) for e in events[:3]) + " Stay safe out there."
    prompt = apply_language(prompt, req)
    body = {"model": ollama.model_for("bulletin"), "messages": [{"role": "system", "content": prompt},
                                                            {"role": "user", "content": "[on air]"}],
            "stream": True, "keep_alive": args.keep_alive,
            "options": dict(ollama.options_for(ollama.model_for("bulletin")) if hasattr(ollama, "options_for") else ollama.options(),
                            num_predict=200, temperature=0.8),
            "format": NEWS_SCHEMA if ollama.schema_ok else "json"}
    out = ollama.stream(body, should_abort, ollama.deadline_for("bulletin") if hasattr(ollama, "deadline_for") else None)
    if out is None:
        return None
    try:
        text = json.loads(((out.get("message") or {}).get("content")) or "{}").get("say") or ""
    except (ValueError, AttributeError):
        text = ""
    text = clean_reply(text)[:480]
    return text


def story_bits(job, args, ollama, should_abort=None):
    """Persistent 2-4 sentence backstory consistent with personality, profession, faction and 1993 Knox County."""
    pz = job.get("persona") or {}
    npc = job.get("npc") or {}
    if args.echo:
        return None
    prompt = (STATIC_HEAD + "\nWrite the private backstory of this survivor as JSON with four short sentences (max 25 "
              "words each, third person): before = their life before the outbreak, lost = who they lost, survived = how they "
              "survived the first weeks, secret = a secret or regret. Kentucky 1993, Knox County towns only (Muldraugh, West "
              "Point, Riverside, Rosewood, March Ridge, Louisville). Grounded, specific, no superpowers, no cures.\n"
              f"Name: {_s(npc.get('name'), 40)}. Sex: {_s(npc.get('sex'), 2)}. Role: {_s(npc.get('title') or npc.get('role'), 60)}. "
              f"Group: {_s(npc.get('faction'), 50)}. Personality: {_s(pz.get('line'), 260)}. "
              f"Ideas you may use or improve: {_s(' '.join(pz.get('fallback') or []), 500)}")
    body = {"model": ollama.model_for("story"), "messages": [{"role": "system", "content": prompt},
                                                             {"role": "user", "content": "[backstory]"}],
            "stream": True, "keep_alive": args.keep_alive,
            "options": dict(ollama.options_for(ollama.model_for("story")) if hasattr(ollama, "options_for") else ollama.options(),
                            num_predict=220, temperature=0.85),
            "format": STORY_SCHEMA if ollama.schema_ok else "json"}
    if hasattr(ollama, "begin"):
        ollama.begin("story")
    out = ollama.stream(body, should_abort, ollama.deadline_for("story") if hasattr(ollama, "deadline_for") else None)
    if out is None:
        return None
    try:
        d = json.loads(((out.get("message") or {}).get("content")) or "{}")
    except ValueError:
        return []
    bits = [clean_reply(d.get(k) or "") for k in ("before", "lost", "survived", "secret")]
    return [b for b in bits if b and len(b) > 12]


def handle(req, args, ollama, should_abort=None):
    try:  # 0.8.12: prompts files changed since the last line? re-read them (two stat calls)
        PROMPTS.refresh(sys.modules[__name__], getattr(args, "dir", None), log=log)
    except Exception as e:  # never let a bad prompts file stop a reply
        log("prompts: could not read (%s); built-in text used" % e)
    if req.get("mode") == "bulletin":
        text = news_bulletin(req, args, ollama, should_abort)
        if text is None:
            return None, {"aborted": True}
        return {"tone": "NONE", "act": "NONE", "d": 0, "leave": False, "say": text}, {}
    acts = [a for a in (req.get("acts") or []) if isinstance(a, str)]
    if req.get("mode") == "speak":  # v0.5.1: a fixed line from the game, voiced only (no model call)
        return {"tone": "NONE", "act": "NONE", "d": 0, "leave": False, "say": _s(req.get("text"), 300)}, {}
    if req.get("mode") in ("note", "event"):  # memory-only event (A-Life spoke its own line); nothing to generate
        return {"tone": "NONE", "act": "NONE", "d": 0, "leave": False, "say": ""}, {}
    if req.get("mode") == "hear":  # v3.2 overheard line: judged by the lexicon only (no model call, instant)
        h = req.get("hear") or {}
        j = judge_line(req.get("said"))
        named = any(isinstance(l, dict) and l.get("named") for l in (h.get("listeners") or []))
        # talking ABOUT someone: "janet is a useless idiot" (an insult word anywhere counts when they were named)
        m = _ABOUT_INSULT.search(j["low"])
        if named and not j["hostile"] and m and not _NEGATED.search(j["low"][:m.start()][-20:]):
            j["rude"] = j["hostile"] = True
        d = (-5 if j["threat"] else -3) if (j["hostile"] and named) else 0
        return {"tone": "THREATEN" if j["threat"] else "INSULT" if j["rude"] else "NONE", "act": "NONE", "d": d,
                "leave": False, "say": ""}, {}
    if args.echo:
        return {"tone": "NONE", "act": "NONE", "d": 0, "leave": False,
                "say": f"Echo test: you said '{_s(req.get('said'), 120)}'."}, {}
    if req.get("mode") in ("chime", "banter"):
        line = req.get("line") or ["someone", req.get("said")]
        user = f'{_s(line[0], 40)} (to {_s(req.get("lineTo") or "you", 20)}): "{_s(line[1], 200)}"'
    elif req.get("mode") == "gift":
        user = gift_text(req)
    elif req.get("mode") == "death":
        ev = req.get("event") or {}
        user = f"[{_s(ev.get('victim'), 40) or 'Someone'} was just killed right in front of you]"
    elif req.get("mode") == "ambient":
        user = f"[You turn to {_s((req.get('partner') or {}).get('name'), 40) or 'them'} and say something]"
    elif req.get("mode") in REACT_MODES:
        user = f"[{_s((req.get('react') or {}).get('what'), 200) or 'Something happens'}]"
    else:
        user = _s(req.get("said"), 200)
        if not (user or "").strip(" \t\r\n.,!?-"):  # 0.5.1.6: an empty player line is never sent to the model
            return {"tone": "NONE", "act": "NONE", "d": 0, "leave": False, "say": ""}, {"empty": True}
    uid, recent = recent_for(req)
    speaks = req.get("mode") in (None, "", "reply", "radio") or req.get("mode") in REACT_MODES
    recent_txt = ""
    if recent and speaks:
        recent_txt = ("\nYou said these lately - do NOT repeat them or reuse their wording, say something new that "
                      "answers THIS line: " + " | ".join('"' + _s(x, 80) + '"' for x in recent))
    if getattr(args, "no_order_rule", False):
        req["orderRule"] = False
    version_note(req)
    budget = prompt_char_budget(args, user, recent_txt)
    if budget is not None and suggest_rule(req):  # 0.8.3 step 3: the suggestions' reply tokens come out of the prompt
        budget = max(1200, budget - int(SUGGEST_TOKENS * min(3, int(req.get("suggest") or 0)) * CHARS_PER_TOKEN))
    if budget is not None:
        req["_maxChars"] = budget
    req["_profile"] = getattr(args, "profile_name", "normal")
    system = build_system(req)
    if req.get("_cut"):
        log(f"  (prompt fitted to num_ctx {getattr(args, 'num_ctx', '?')}: cut {', '.join(req['_cut'])})")
        if int(getattr(args, "num_ctx", 0) or 0) <= 2048 and not CTX_TIP["shown"]:
            CTX_TIP["shown"] = True  # 0.5.2.8 [pt265u]: once per session
            log("  TIP: num_ctx 2048 is too small for this scene, so parts of the prompt were cut (the core - order rule, "
                "who is dead, what they just said, how they feel - is always kept). Start the bridge with --num-ctx 4096 "
                "(the default since 0.5.2.8 when --num-ctx is not given).")
    try:
        ollama._mode = req.get("mode")  # v0.5.1: per-mode sampler (chatter temperature)
        ollama._extra_predict = (SUGGEST_TOKENS * min(3, int(req.get("suggest") or 0)) if suggest_rule(req) else 0) \
            + (LENGTH_EXTRA_TOKENS.get(length_level(req), 0) if req.get("mode") in (None, "", "reply") else 0) \
            + (CALM_EXTRA["tokens"] if calm_scene(req) and length_level(req) == 2 else 0) \
            + (12 if command_rule(req) else 0) \
            + (6 if want_rule(req) else 0) \
            + (8 if standoff_rule(req) else 0)  # 0.8.2 part 2: room for cmd / cmdItem; 0.8.3 step 10: want
    except Exception:
        pass
    system += recent_txt
    msgs = [{"role": "system", "content": system}, {"role": "user", "content": user}]
    if args.debug_prompt:
        log("PROMPT:\n" + msgs[0]["content"])
    model = ollama.model_for(req.get("mode")) if hasattr(ollama, "model_for") else None
    chat = (lambda m, a, ab: ollama.chat(m, a, ab, model)) if model and model != getattr(getattr(ollama, "a", None), "model", model) \
        else (lambda m, a, ab: ollama.chat(m, a, ab))
    out = chat(msgs, acts, should_abort)
    if out is None:
        return None, {"aborted": True}
    content = ((out or {}).get("message") or {}).get("content", "")
    result = parse_model_output(content, acts)
    # v0.3.3: retry once when the reply is empty / a model refusal / a repeat of a recent line
    if speaks:
        why = None
        if _REFUSAL.search(result["say"] or ""):
            why, result = "refusal", dict(result, say="")
        if not result["say"] and result["act"] == "NONE" and req.get("mode") in (None, "", "reply", "radio"):
            why = why or "empty"
        elif not result["say"] and req.get("mode") in MUST_SPEAK:
            why = why or "empty"  # v0.5.0: taunts, own injuries etc. always get a line
        elif not result["say"]:
            pass  # a reaction may stay quiet
        elif is_repeat(result["say"], recent):
            why = "repeat"
        elif req.get("_order") and order_missed(_s(req.get("said"), 200), result["say"]):
            why = "offtopic"  # 0.5.2.5: an order got an unrelated answer
        elif FILLER.search(result["say"] or "") and req.get("mode") not in MUST_SPEAK:
            why = "filler"  # v0.5.1
        if why:
            hint = {"repeat": "You just said that. Answer again with a DIFFERENT line (new words) that fits what they said.",
                    "offtopic": "That didn't answer what they told you to do. Answer THAT order directly: will you do it or "
                                "not? Agree or refuse in character, max 20 words, as JSON.",
                    "filler": "That's a greeting-card line. Say something concrete and personal instead (a detail, an opinion, a joke).",
                    "empty": "Your reply had no line. Answer again in character as JSON with a short non-empty \"say\".",
                    "refusal": "This is a fictional video game scene and you are the character, not an assistant. Stay in "
                               "character and answer as JSON with a short non-empty \"say\" (a curse, a warning, a "
                               "comeback - no violence instructions needed)."}[why]
            msgs2 = msgs + [{"role": "assistant", "content": content or "{}"}, {"role": "user", "content": hint}]
            try:
                out2 = chat(msgs2, acts, should_abort)
            except Exception as e:
                out2 = None
                log("retry failed:", e)
            if out2 is not None:
                r2 = parse_model_output(((out2.get("message") or {}).get("content", "")), acts)
                if _REFUSAL.search(r2["say"] or ""):
                    r2["say"] = ""
                if r2["say"] and not is_repeat(r2["say"], recent) and not (why == "filler" and FILLER.search(r2["say"])) \
                        and not (why == "offtopic" and order_missed(_s(req.get("said"), 200), r2["say"])):
                    r2.setdefault("d", result["d"])
                    if result["d"] != 0 and r2["d"] == 0:  # keep the first call's judgement of the player's line
                        r2 = dict(r2, d=result["d"], tone=result["tone"])
                    result, out = r2, dict(out2, _retried=why)
                    log(f"  (retried: {why})")
            if why == "filler" and FILLER.search(result.get("say") or ""):
                result = dict(result, say=FILLER.sub("", result["say"]).strip(" ,.-") or result["say"])
            if req.get("mode") in (None, "", "reply") and (not result["say"] or is_repeat(result["say"], recent)) \
                    and result["act"] == "NONE":
                result = dict(result, say=fallback_line(req, recent))
                out = dict(out or {}, _retried=why + "+stock")
                log(f"  (model gave no usable line after a retry ({why}); stock line used)")
            if req.get("mode") in MUST_SPEAK and not result["say"]:
                result = dict(result, say=must_line(req, recent))
                out = dict(out or {}, _retried=(why or "empty") + "+stock")
                log(f"  (no line after a retry; stock {req.get('mode')} line used)")
    if req.get("mode") in CHATTER_MODES and FILLER.search(result.get("say") or ""):  # v0.5.1: no greeting-card small talk
        hint = "That's a greeting-card line. Say something concrete and personal instead (a detail, an opinion, a joke)."
        try:
            out2 = chat(msgs + [{"role": "assistant", "content": content or "{}"}, {"role": "user", "content": hint}], acts, should_abort)
        except Exception as e:
            out2 = None
            log("retry failed:", e)
        r2 = parse_model_output(((out2 or {}).get("message") or {}).get("content", ""), acts) if out2 else None
        if r2 and r2.get("say") and not FILLER.search(r2["say"]):
            result, out = dict(result, say=r2["say"]), dict(out2, _retried="filler")
            log("  (retried: filler)")
        else:
            result = dict(result, say=FILLER.sub("", result["say"]).strip(" ,.-!"))
    if req.get("mode") in REACT_MODES or req.get("mode") == "death":
        result = dict(result, d=0, act="NONE", leave=False, tone="NONE")
    result = dict(result, sokind=clean_sokind(req, result.get("sokind")) if standoff_rule(req) else "")  # 0.8.5
    if result.get("ask") and not askback_rule(req):
        result = dict(result, ask=False)  # 0.8.3 step 4: only a reply the mod asked for may ask back
    if result.get("want"):  # 0.8.3 step 10: only a kind the mod offered, never while leaving or fighting
        wv = clean_want(req, result.get("want"))
        if result.get("leave") or (req.get("fight") or {}).get("hostile"):
            wv = ""
        result = dict(result, want=wv)
    if result.get("cmd"):  # 0.8.2 part 2: only a listed command, never while leaving or fighting
        c = clean_cmd(req, result.get("cmd"))
        fight = req.get("fight") or {}
        if not c or result.get("leave") or fight.get("hostile"):
            c = ""
        result = dict(result, cmd=c, cmdItem=result.get("cmdItem") if c else "")
    if req.get("mode") == "thought" and result.get("say") and (req.get("pronounFix") is not False):
        fixed = fix_pronouns(result["say"], (req.get("you") or {}).get("sex"))
        if fixed != result["say"]:
            log("  (pronouns fixed)")
            result = dict(result, say=fixed)
    if req.get("mode") in ("ambient", "chime", "banter") and req.get("speakerUid") and result.get("say"):
        tag, pd = pair_tag(result["say"], result.get("tone", "NONE"), result.get("d", 0))
        result = dict(result, pair=tag, pd=pd, d=0, act="NONE", leave=False)  # v0.5.1: NPC-NPC bond change
    if req.get("mode") in (None, "", "reply", "radio") and not args.raw_scores:
        result, notes = calibrate(result, req)
        if notes:
            (out or {})["_calibrated"] = notes
        fight = req.get("fight") or {}
        if fight.get("hostile") or fight.get("fighting"):
            result = dict(result, leave=False, act="NONE")
    if speaks and result.get("say"):
        cut = limit_catchphrase(result["say"], catchphrase_of(req), recent)
        if cut != result["say"]:
            log("  (catchphrase dropped: said it just now)")
            result = dict(result, say=cut)
        remember_said(uid, result["say"])
    return result, out or {}


def read_request(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            raw = f.read().strip()
    except FileNotFoundError:
        return None
    if not raw:
        return None
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return None  # partially written; next poll


_VER_WARNED = {"done": False}


def _ver_tuple(v):
    return tuple(int(x) for x in re.findall(r"\d+", str(v or "")))


def version_note(req):
    """0.5.2.6: log once when the mod in the game is newer than this bridge (the mod warns in-game the other way)."""
    mv = req.get("modv") if isinstance(req, dict) else None
    if _VER_WARNED["done"] or not mv:
        return False
    if _ver_tuple(mv) > _ver_tuple(VERSION):
        _VER_WARNED["done"] = True
        log(f"WARNING: the mod in the game is {mv} but this bridge is {VERSION} - start ALifeTalk_Bridge.bat from the "
            f"{mv} zip (replace the whole ALifeTalk_Bridge folder).")
        return True
    return False


def set_console_title():
    """0.5.2.6: the window title shows the real bridge version (the .bat title used to be a stale hard-coded '0.5.0')."""
    if os.name != "nt":
        return False
    try:
        import ctypes
        ctypes.windll.kernel32.SetConsoleTitleW(f"A-Life Talk bridge {VERSION} (leave this window open while playing)")
        return True
    except Exception:
        return False


def run(args):
    d = args.dir
    os.makedirs(d, exist_ok=True)
    req_path, reply_path, status_path = (os.path.join(d, n) for n in (REQ, REPLY, STATUS))
    set_console_title()
    log(f"A-Life Talk bridge {VERSION} watching {d}")
    cloud = {} if args.echo or getattr(args, "no_cloud", False) else load_cloud(d)
    ollama = CloudLLM(args, cloud) if cloud else Ollama(args)
    if args.echo:
        log("Mode: ECHO (no AI)")
    elif cloud:
        args.model = cloud["model"]
        args.profile_name = cloud.get("profile") or "full"
        log(f"Cloud AI: {cloud['model']} at {cloud['url']}  (background {cloud['background']}, max {cloud['max_per_hour']} "
            f"requests/hour, profile {args.profile_name}; key from {CLOUD_FILE}, not logged)")
        try:
            log(f"Cloud AI answered the test in {ollama.preload():.1f}s")
        except Exception as e:
            log(f"WARNING: cloud AI test failed ({e}). Check {CLOUD_FILE} in your Zomboid\\Lua folder.")
    else:
        log(f"Model: {args.model} at {args.ollama}  (num_predict {args.num_predict}, num_ctx {args.num_ctx}, profile {getattr(args, 'profile_name', 'normal')})")
        try:
            with urllib.request.urlopen(args.ollama.rstrip("/") + "/api/tags", timeout=5) as r:
                names = [m.get("name") for m in json.loads(r.read().decode("utf-8")).get("models", [])]
            if not any(n == args.model or (n or "").split(":")[0] == args.model for n in names):
                log(f"WARNING: model '{args.model}' not found. Run:  ollama pull {args.model}")
            elif not args.no_preload:
                log("Loading the model into memory (first time can take a while)...")
                write_atomic(status_path, "loading\n")
                log(f"Model ready in {ollama.preload():.1f}s")
        except Exception as e:
            log(f"WARNING: {ollama_error_kind(e, args.model, args.ollama)}")
    if getattr(args, "dialogue_model", ""):
        log(f"Dialogue model (replies to you): {args.dialogue_model}")
    if getattr(args, "background_model", ""):
        log(f"Background model: {args.background_model}" + (" (on CPU)" if getattr(args, "bg_on_cpu", False) else ""))
    watch = GameWatch(args) if getattr(args, "exit_with_game", False) else None
    voice = None
    push_path0 = os.path.join(d, PUSH)
    if getattr(args, "voice", "none") not in ("none", None, ""):
        try:
            from alifetalk_voice import Voice
            voice = Voice(args, log, lambda kind, uid, fields: push(push_path0, kind, uid, fields))
        except Exception as e:
            log(f"voice: unavailable ({e})")
    speak_modes = set(x.strip() for x in (getattr(args, "speak_modes", "") or "").split(",") if x.strip())
    memory = None
    if not args.no_memory:
        if args.fold_every:
            import alifetalk_memory
            alifetalk_memory.FOLD_EVERY = args.fold_every
        memory = Memory(args.mem_dir)
        log(f"Memory: {args.mem_dir}")
        if getattr(args, "embed_model", ""):
            os.makedirs(args.mem_dir, exist_ok=True)
            memory.embedder = Embedder(args.ollama, args.embed_model, os.path.join(args.mem_dir, "vectors.json"))
            log(f"Memory retrieval: embeddings with {args.embed_model} (keyword fallback)")
    last_req_at = 0.0
    last_id = None
    old = read_request(req_path)  # don't answer a stale request from an earlier session (older than 15 s)
    try:
        fresh = time.time() - os.path.getmtime(req_path) < 15
    except OSError:
        fresh = False
    if isinstance(old, dict) and not fresh:
        last_id = old.get("id")
    last_beat, processed = 0, 0
    last_story_at = 0.0
    story_todo = {}
    push_path = os.path.join(d, PUSH)
    last_embed = 0.0
    reporter = None
    if Reporter is not None:
        try:
            reporter = Reporter(d, log=log)
        except Exception as e:  # noqa: BLE001
            log("bug reports unavailable:", e)
    while True:
        now = time.time()
        if reporter is not None:
            try:
                reporter.tick(now)
            except Exception as e:  # noqa: BLE001
                log("bug report check failed:", e)
                reporter = None
        if watch is not None and watch.should_exit():
            log("Project Zomboid is closed - bridge exiting." if watch.seen else "Project Zomboid never started - bridge exiting.")
            try:
                write_atomic(status_path, "stopped\n")
            except Exception:
                pass
            if memory is not None:
                try:
                    memory.save()
                    if memory.embedder is not None:
                        memory.embedder.save()
                except Exception:
                    pass
            return
        if now - last_beat >= 1:
            try:
                write_atomic(status_path, f"alive {int(now)} {args.model} ver={VERSION}\n")
            except Exception as e:
                log("status write failed:", e)
            last_beat = now
        req = read_request(req_path)
        if isinstance(req, dict) and req.get("id") and req.get("id") != last_id:
            last_id = req["id"]
            t0 = time.perf_counter()
            try:  # v0.4.0 latency instrumentation: how long the request sat in the file before we saw it
                seen_lag = max(0.0, (time.time() - os.path.getmtime(req_path)) * 1000)
            except OSError:
                seen_lag = 0.0
            if memory is not None:
                try:
                    req["_memory"] = memory.prompt_block(req)
                    if req.get("uid"):
                        st = memory.story_of(req.get("worldId"), req["uid"])
                        if st:
                            req["_story"] = " ".join(st["bits"])
                        elif isinstance(req.get("persona"), dict) and req["persona"].get("needStory"):
                            story_todo[(req.get("worldId"), req["uid"])] = {"persona": req["persona"], "npc": req.get("npc") or {}}
                    for il in (req.get("ilog") or [])[:20]:  # interaction log rows piggy-backed on any request
                        if isinstance(il, dict) and il.get("uid"):
                            memory.add_interactions(req.get("worldId"), il["uid"], il.get("name"), il.get("rows") or [])
                            if isinstance(il.get("forget"), list) and hasattr(memory, "forget_interactions"):
                                memory.forget_interactions(req.get("worldId"), il["uid"], il["forget"])  # 0.5.2.5 save clean-up
                except Exception as e:
                    log("memory read failed:", e)
            prep_ms = (time.perf_counter() - t0) * 1000
            npc = _s((req.get("npc") or {}).get("name")) or \
                ("Knox County Radio" if req.get("mode") == "bulletin" else "someone")  # v0.5.0: no more "NPC" speaker
            if req.get("mode") == "event":
                ev = req.get("event") or {}
                log(f"> event for {len(ev.get('witnesses') or [])} NPC(s): {_s(ev.get('what'), 100)} {_s(ev.get('where'), 60)}")
            elif req.get("mode") == "death":
                log(f"> {npc} witnesses: {_s((req.get('event') or {}).get('what'), 100)}")
            elif req.get("mode") in ("gift", "note"):
                log(f"> {npc} {'is handed' if req.get('mode') == 'gift' else 'got (A-Life hand-over, memory only)'}: "
                    f"{gift_text(req)}")
            elif req.get("mode") == "ambient":
                log(f"> {npc} (ambient) turns to {_s((req.get('partner') or {}).get('name'), 40)}")
            elif req.get("mode") in ("chime", "banter"):
                log(f"> {npc} overhears ({req.get('mode')}): {_s((req.get('line') or ['', ''])[1], 120)}")
            elif req.get("mode") in REACT_MODES:
                log(f"> {npc} ({req.get('mode')}): {_s((req.get('react') or {}).get('what'), 120)}")
            elif req.get("mode") == "bulletin":
                log(f"> radio bulletin from {len((req.get('bulletin') or {}).get('events') or [])} report(s)")
            elif req.get("mode") == "hear":
                log(f"> overheard by {len((req.get('hear') or {}).get('listeners') or [])} NPC(s): {_s(req.get('said'), 120)}")
            elif not (_s(req.get('said'), 200) or "").strip(" \t\r\n.,!?-"):
                log(f"> (empty line to {npc} skipped - nothing to answer)")
            else:
                log(f"> you {'radio' if req.get('mode') == 'radio' else 'to'} {npc}: {_s(req.get('said'), 200)}")
            out = {}
            mode = req.get("mode") or "reply"
            my_id = last_id

            def superseded():
                newer = read_request(req_path)
                return isinstance(newer, dict) and newer.get("id") not in (None, my_id)

            def newer_player_line():
                # v0.4.2: a reply in flight keeps the request file watched too. The game only writes a newer player
                # line after it gave up on this one, so that one wins; background requests wait their turn.
                newer = read_request(req_path)
                return (isinstance(newer, dict) and newer.get("id") not in (None, my_id)
                        and (newer.get("mode") or "reply") in PLAYER_MODES)
            if hasattr(ollama, "begin"):
                ollama.begin(mode)
            fail_why = "no usable line"  # 0.8.11.2: told to the game, so its console says why A-Life answered
            try:
                # v0.4.0: everything but the player's own reply / radio call / gift gives way the moment the player speaks
                result, out = handle(req, args, ollama, newer_player_line if mode in PLAYER_MODES else superseded)
            except OllamaBusy as e:
                log(f"  ({e}; the game uses A-Life's own line)")
                result, fail_why = None, f"busy: {e}"
            except DeadlineExceeded as e:
                log(f"  TIMEOUT: {e}")
                result, fail_why = None, f"timeout ({getattr(args, 'model', '?')})"
            except Exception as e:
                why = ollama_error_kind(e, getattr(args, "model", "?"), getattr(args, "ollama", ""))
                log(f"ERROR talking to Ollama: {why}")
                result, fail_why = None, why
            ms = (time.perf_counter() - t0) * 1000
            if out.get("aborted"):
                log("  (dropped: you spoke again, answering you first)")
            elif mode != "reply" and result is not None:
                write_atomic(reply_path, format_reply_file(last_id, result, ms))  # empty say = stays quiet
                log(f"< {npc}: {result['say'] or '(stays quiet)'}  {ms:.0f} ms"
                    + (f"  [d {result['d']:+d} tone {result['tone']}]" if mode == "hear" else "")
                    + (f"  [d {result['d']:+d} tone {result['tone']}"
                       + (f", adjusted: {', '.join(out['_calibrated'])}" if out.get("_calibrated") else "") + "]"
                       if mode == "radio" else ""))
            elif result is not None and result["say"] or (result is not None and result["act"] != "NONE"):
                write_atomic(reply_path, format_reply_file(last_id, result, ms))
                llm_ms = (out.get("total_duration") or 0) / 1e6
                tok = out.get("eval_count")
                log(f"< {npc}: {result['say']}  [d {result['d']:+d} tone {result['tone']} act {result['act']}"
                    f"{' leave' if result['leave'] else ''}] {ms:.0f} ms"
                    + (f" (adjusted: {', '.join(out['_calibrated'])})" if out.get("_calibrated") else "")
                    + (f" (model {llm_ms:.0f} ms, load {(out.get('load_duration') or 0)/1e6:.0f} ms, "
                       f"prompt {out.get('prompt_eval_count')} tok, reply {tok} tok)" if llm_ms else ""))
            else:
                one = str(fail_why).replace("\r", " ").replace("\n", " ")[:160]
                write_atomic(reply_path, f"id={last_id}\nfail=1\nwhy={one}\nms={int(ms)}\ntext=\n")
                log(f"no usable reply ({one}); the game falls back now")
            if args.timing or ms - (out.get("total_duration") or 0) / 1e6 > 1500:
                log(f"  timing: seen {seen_lag:.0f} ms after the game wrote it, prep {prep_ms:.0f} ms, "
                    f"model {(out.get('total_duration') or 0) / 1e6:.0f} ms, total {ms:.0f} ms")
            if voice is not None and result is not None and result.get("say") and not out.get("aborted"):
                kind = "written" if mode in WRITTEN_MODES else ("react" if mode in REACT_MODES else mode)
                if kind in speak_modes:
                    vz = req.get("voice") or {}
                    voice.speak(req.get("uid") or npc, vz.get("sex") or (req.get("npc") or {}).get("sex"), vz.get("age"),
                                result["say"], radio=(mode == "radio"))
            if memory is not None and result is not None and not out.get("aborted"):
                try:
                    memory.record(req, result)  # after the reply file is written: no added latency
                except Exception as e:
                    log("memory write failed:", e)
            last_req_at = time.time()
            processed += 1
            if args.once and processed >= args.once:
                return
        elif memory is not None and story_todo and time.time() - last_req_at >= max(args.summary_idle, getattr(args, "story_idle", 3.0)) \
                and time.time() - last_story_at >= getattr(args, "story_gap", 20.0):
            last_story_at = time.time()  # v0.4.2: at most one backstory per ~20 s, only after 3 s of quiet
            (world, suid), job = story_todo.popitem()
            if memory.story_of(world, suid) is None:
                my = last_id

                def interrupted():
                    newer = read_request(req_path)
                    return isinstance(newer, dict) and newer.get("id") not in (None, my)
                t1 = time.perf_counter()
                try:
                    bits = story_bits(job, args, ollama, interrupted)
                except Exception as e:
                    bits = []
                    log("backstory failed:", e)
                if bits is None and not args.echo:
                    story_todo[(world, suid)] = job  # someone spoke; later
                else:
                    src = "llm"
                    if not bits:
                        bits, src = [b for b in (job["persona"].get("fallback") or []) if isinstance(b, str)], "template"
                    if bits:
                        memory.set_story(world, suid, bits, src)
                        push(push_path, "story", suid, [src] + bits)
                        log(f"  backstory ({src}) for {_s((job.get('npc') or {}).get('name'), 40)} in "
                            f"{(time.perf_counter() - t1) * 1000:.0f} ms")
            last_req_at = time.time()
        elif memory is not None and memory.todo and time.time() - last_req_at >= args.summary_idle:
            summarize_one(memory, args, ollama, req_path, last_id)
            last_req_at = time.time()
        elif memory is not None and memory.embedder is not None and time.time() - last_req_at >= 2.0 \
                and time.time() - last_embed >= 3.0:
            last_embed = time.time()  # v0.5.0: embed memories while idle (a few per pass)
            try:
                if memory.embed_idle(4):
                    memory.embedder.save()
            except Exception as e:
                log("memory embedding failed:", e)
        elif memory is not None and memory.dirty and time.time() - last_req_at >= 1.0:
            try:
                memory.save()  # v0.4.0: interaction-log rows are flushed while idle, never before a reply
            except Exception as e:
                log("memory save failed:", e)
        time.sleep(args.poll)


def fit_summary_chunk(data, chunk, args):
    """0.5.2.2: a backlog of unsummarized lines (long chats while the model was busy) made one summary prompt far
    bigger than num_ctx - Ollama cut its start (the instructions and the old summary). Oldest lines first, as many as fit."""
    try:
        ctx = int(getattr(args, "num_ctx", 2048) or 2048)
    except Exception:
        ctx = 2048
    budget = int((ctx - 200 - PROMPT_MARGIN_TOKENS) * CHARS_PER_TOKEN)
    chunk = list(chunk)
    while len(chunk) > 4:
        msgs = Memory.summary_prompt(data, chunk)
        if sum(len(m["content"]) for m in msgs) <= budget:
            break
        chunk = chunk[:max(4, int(len(chunk) * 0.8))]
    return chunk


def summarize_one(memory, args, ollama, req_path, last_id):
    """Fold older memory into the rolling summary while nobody is talking; aborts as soon as a request arrives."""
    job = memory.next_job()
    if job is None:
        return
    p, data, start, end = job
    chunk = fit_summary_chunk(data, data["entries"][start:end], args)
    end = start + len(chunk)  # 0.5.2.2: the rest is folded by the next job
    t0 = time.perf_counter()

    def interrupted():
        newer = read_request(req_path)
        return isinstance(newer, dict) and newer.get("id") not in (None, last_id)
    try:
        if args.echo:
            memory.fold_cheap(data, chunk)
            data["folded"] = end
            memory.dirty.add(p)
            memory.save(p)
            ok = True
        else:
            content = ollama.summarize(Memory.summary_prompt(data, chunk), interrupted)
            if content is None:
                memory.todo.add(p)  # someone spoke; try again later
                return
            ok = memory.apply_summary(p, data, end, content)
        log(f"  memory: summarized {len(chunk)} older lines for {data.get('name') or data.get('uid')}"
            f" in {(time.perf_counter() - t0) * 1000:.0f} ms" + ("" if ok else " (model gave no summary, kept as is)"))
    except Exception as e:
        log("memory summary failed:", e)


# ---------------------------------------------------------------- v0.5.0: VRAM advice, game watcher
MODEL_GB = {"stheno": 4.9, "8b": 4.9, "7b": 4.4, "3b": 2.0, "3.2:3b": 2.0, "1b": 0.9, "nomic": 0.3, "12b": 7.5, "4b": 2.6}


def model_gb(name):
    n = (name or "").lower()
    for k, v in sorted(MODEL_GB.items(), key=lambda kv: -len(kv[0])):
        if k in n:
            return v
    return 4.5


def vram_advice(args):
    import subprocess
    total = used = None
    try:
        out = subprocess.run(["nvidia-smi", "--query-gpu=name,memory.total,memory.used", "--format=csv,noheader,nounits"],
                             capture_output=True, text=True, timeout=10).stdout.strip().splitlines()[0]
        name, total, used = [x.strip() for x in out.split(",")]
        total, used = float(total) / 1024, float(used) / 1024
        log(f"GPU: {name}, {total:.1f} GB total, {used:.1f} GB in use now")
    except Exception as e:
        log(f"nvidia-smi not available ({e}); assuming 12 GB")
        total, used = 12.0, 0.0
    game = 4.0
    main_m = args.dialogue_model or args.model
    need = model_gb(main_m) + 0.8 + (0.5 if int(getattr(args, "num_ctx", 0) or 0) > 2048 else 0)  # weights + KV cache (4096 adds ~0.5 GB)
    bg = args.background_model
    if bg and bg != main_m:
        need += 0 if args.bg_on_cpu else model_gb(bg) + 0.5
    if args.embed_model:
        need += 0.3
    log(f"Estimated: models {need:.1f} GB + Project Zomboid ~{game:.0f} GB = {need + game:.1f} GB of {total:.1f} GB")
    if need + game <= total - 0.5:
        log("OK: everything fits on the GPU. Set OLLAMA_MAX_LOADED_MODELS=3 so Ollama keeps them all loaded.")
    else:
        log("TIGHT: use one of these:\n  a) --bg-on-cpu  (background model on the CPU; slower chatter, replies stay fast)\n"
            "  b) no --background-model (one model does everything)\n"
            "  c) set OLLAMA_FLASH_ATTENTION=1 and OLLAMA_KV_CACHE_TYPE=q8_0 (smaller KV cache)\n"
            "  d) a smaller dialogue model (llama3.2:3b) ")


class GameWatch:
    """--exit-with-game: Project Zomboid's process (tasklist on Windows, ps elsewhere). Exits once the game was seen
    and is gone for 20 s, or if it never shows up within --game-wait seconds."""
    NAMES = ("projectzomboid64.exe", "projectzomboid32.exe", "projectzomboid.exe", "projectzomboid64", "projectzomboid")

    def __init__(self, args):
        self.a = args
        self.start = time.time()
        self.seen = False
        self.gone_since = None
        self.next = 0

    def running(self):
        import subprocess
        try:
            if os.name == "nt":
                out = subprocess.run(["tasklist", "/FO", "CSV", "/NH"], capture_output=True, text=True, timeout=10,
                                     creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0)).stdout.lower()
            else:
                out = subprocess.run(["ps", "-A", "-o", "comm="], capture_output=True, text=True, timeout=10).stdout.lower()
        except Exception:
            return None
        return any(n in out for n in self.NAMES) or "zomboid" in out and "java" in out

    def should_exit(self):
        now = time.time()
        if now < self.next:
            return False
        self.next = now + 5
        r = self.running()
        if r is None:
            return False
        if r:
            if not self.seen:
                log("Project Zomboid detected; the bridge will close when the game closes.")
            self.seen, self.gone_since = True, None
            return False
        if not self.seen:
            return now - self.start > self.a.game_wait
        self.gone_since = self.gone_since or now
        return now - self.gone_since > 20


def normalize_ollama(url):
    """'0.0.0.0', 'localhost:11434', 'http://localhost' (OLLAMA_HOST is often set for the server side) -> a URL we can
    call: http, 127.0.0.1 instead of localhost / 0.0.0.0 (Windows tries IPv6 first for localhost: ~2 s per request),
    and Ollama's port 11434 when none is given."""
    url = (url or "").strip().rstrip("/") or "http://127.0.0.1:11434"
    if not url.startswith("http"):
        url = "http://" + url
    url = re.sub(r"//(localhost|0\.0\.0\.0)(?=[:/]|$)", "//127.0.0.1", url)
    if not re.match(r"^https?://(\[[^\]]+\]|[^/:]+):\d+", url):
        url = re.sub(r"^(https?://(\[[^\]]+\]|[^/:]+))", r"\1:11434", url)
    return url


def main(argv=None):
    p = argparse.ArgumentParser(description="A-Life Talk <-> Ollama bridge")
    p.add_argument("--profile", default=os.environ.get("ALIFETALK_PROFILE", ""), help="lite / normal / full (default: by model size)")
    p.add_argument("--model", default=os.environ.get("ALIFETALK_MODEL", DEFAULT_MODEL))
    p.add_argument("--dir", default=default_dir())
    p.add_argument("--dump-prompts", dest="dump_prompts", default="", help="0.8.12: write the built-in prompt text as a prompts file and exit")
    # v0.4.0: 127.0.0.1, not localhost - on Windows "localhost" tries IPv6 first and can add ~2 s per request
    p.add_argument("--ollama", default=os.environ.get("OLLAMA_HOST", "http://127.0.0.1:11434"))
    p.add_argument("--background-model", dest="background_model", default=os.environ.get("ALIFETALK_BG_MODEL", ""),
                   help="optional second model for ambient chatter, reactions, summaries, backstories and radio news "
                        "(default: the main model)")
    p.add_argument("--repeat-penalty", dest="repeat_penalty", type=float, default=1.1)
    p.add_argument("--min-p", dest="min_p", type=float, default=0.08, help="v0.5.1 min_p sampler (0 = off)")
    p.add_argument("--top-k", dest="top_k", type=int, default=50, help="v0.5.1 top_k sampler (0 = off)")
    p.add_argument("--top-p", dest="top_p", type=float, default=0.9)
    p.add_argument("--chatter-temperature", dest="chatter_temperature", type=float, default=1.0,
                   help="v0.5.1 temperature for NPC-NPC small talk (more variety); 0 = same as --temperature")
    p.add_argument("--repeat-last-n", dest="repeat_last_n", type=int, default=128)
    p.add_argument("--timeout", type=float, default=30)
    p.add_argument("--deadlines", default=os.environ.get("ALIFETALK_DEADLINES", ""),
                   help="per-request hard limits in seconds, e.g. reply=25,story=12,summary=20,bulletin=25,bg=12")
    p.add_argument("--probe-timeout", dest="probe_timeout", type=float, default=10,
                   help="health check (one-token test generation) limit after a timeout")
    p.add_argument("--story-idle", dest="story_idle", type=float, default=float(os.environ.get("ALIFETALK_STORY_IDLE", 3)),
                   help="seconds of silence before a background backstory is written")
    p.add_argument("--story-gap", dest="story_gap", type=float, default=float(os.environ.get("ALIFETALK_STORY_GAP", 20)),
                   help="at most one AI backstory per this many seconds (background, lowest priority)")
    p.add_argument("--poll", type=float, default=0.02)
    p.add_argument("--num-predict", dest="num_predict", type=int, default=80)
    p.add_argument("--calm-extra", dest="calm_extra", type=int, default=20,
                   help="PLAN-CONVO P1: extra reply tokens in calm scenes at length 2 (0 = off)")
    p.add_argument("--num-ctx", dest="num_ctx", type=int, default=int(os.environ.get("ALIFETALK_NUM_CTX", 0) or 0),
                   help="model context in tokens (default 4096; falls back to 2048 once if Ollama can't run it)")
    p.add_argument("--temperature", type=float, default=0.7)
    p.add_argument("--keep-alive", dest="keep_alive", default="60m")
    p.add_argument("--no-preload", dest="no_preload", action="store_true")
    p.add_argument("--echo", action="store_true", help="test mode: no AI, just echo")
    p.add_argument("--mem-dir", dest="mem_dir", default=None,
                   help="memory folder (default: <dir>/alifetalk_mem)")
    p.add_argument("--no-memory", dest="no_memory", action="store_true", help="disable persistent memory")
    p.add_argument("--summary-idle", dest="summary_idle", type=float, default=2.0,
                   help="seconds of silence before background memory summaries run")
    p.add_argument("--fold-every", dest="fold_every", type=int, default=0, help=argparse.SUPPRESS)
    p.add_argument("--raw-scores", dest="raw_scores", action="store_true",
                   help="don't bound the model's opinion change / tone / action by the player's words")
    p.add_argument("--timing", action="store_true", help="log per-stage timing for every request")
    p.add_argument("--debug-prompt", dest="debug_prompt", action="store_true", help="log the full system prompt")
    p.add_argument("--no-order-rule", dest="no_order_rule", action="store_true",
                   help="0.5.2.5: don't add the 'answer the order' rule / retry for orders like 'shoot to kill bandits'")
    p.add_argument("--once", type=int, default=0, help=argparse.SUPPRESS)
    # ---- v0.5.0
    p.add_argument("--dialogue-model", dest="dialogue_model", default=os.environ.get("ALIFETALK_DIALOGUE_MODEL", ""),
                   help="model for replies to the player (e.g. an RP fine-tune); --model / --background-model do the rest")
    p.add_argument("--bg-on-cpu", dest="bg_on_cpu", action="store_true",
                   help="run the background model on the CPU (num_gpu 0) so it does not take VRAM from the game")
    p.add_argument("--vram-check", dest="vram_check", action="store_true", help="print GPU memory advice (nvidia-smi) and exit")
    p.add_argument("--embed-model", dest="embed_model", default=os.environ.get("ALIFETALK_EMBED_MODEL", ""),
                   help="optional Ollama embedding model for memory retrieval (e.g. nomic-embed-text); keyword retrieval otherwise")
    p.add_argument("--voice", choices=("none", "in", "out", "both"), default=os.environ.get("ALIFETALK_VOICE", "none"),
                   help="in = push-to-talk (faster-whisper), out = NPC voices (Piper), both")
    p.add_argument("--whisper-model", dest="whisper_model", default="small.en")
    p.add_argument("--whisper-device", dest="whisper_device", default="cpu", choices=("cpu", "cuda", "auto"))
    p.add_argument("--ptt-key", dest="ptt_key", default="", help="optional global push-to-talk hotkey, e.g. caps lock or f9")
    p.add_argument("--voices-dir", dest="voices_dir", default="", help="folder with Piper .onnx voices (default: ./voices)")
    p.add_argument("--speak-modes", dest="speak_modes", default="reply,radio,gift,react,ambient,chime,banter,death,speak",
                   help="which kinds of NPC lines get a voice")
    p.add_argument("--no-cloud", dest="no_cloud", action="store_true", help="0.5.1: ignore alifeai_cloud.txt (use Ollama)")
    p.add_argument("--exit-with-game", dest="exit_with_game", action="store_true",
                   help="quit when Project Zomboid closes (and if it never starts within --game-wait seconds)")
    p.add_argument("--game-wait", dest="game_wait", type=float, default=600)
    args = p.parse_args(argv)
    CALM_EXTRA["tokens"] = max(0, int(getattr(args, "calm_extra", 20) or 0))
    if args.dump_prompts:  # 0.8.12
        with open(args.dump_prompts, "w", encoding="utf-8", newline="\n") as f:
            f.write(PROMPTS.dump(sys.modules[__name__]))
        print("wrote " + args.dump_prompts)
        return 0
    dl = {}
    for part in (args.deadlines or "").split(","):
        k, _, v = part.partition("=")
        try:
            if k.strip() and float(v) > 0:
                dl[k.strip()] = float(v)
        except ValueError:
            pass
    args.deadlines = dl
    resolve_num_ctx(args)
    args.profile_name = pick_profile(getattr(args, "dialogue_model", None) or args.model, getattr(args, "profile", ""))
    if not args.mem_dir:
        args.mem_dir = os.path.join(args.dir, "alifetalk_mem")
    if not args.ollama.startswith("http"):
        args.ollama = "http://" + args.ollama
    args.ollama = normalize_ollama(args.ollama)
    if args.vram_check:
        vram_advice(args)
        return
    try:
        run(args)
    except KeyboardInterrupt:
        log("bye")


if __name__ == "__main__":
    main()
