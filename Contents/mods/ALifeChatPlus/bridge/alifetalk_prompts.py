"""A-Life NPC Overhaul 0.8.12 (Rock List 2): the AI's prompt text and rules live in plain text files, read LIVE.

Edit, save, and the next line anyone says uses it: no mod update, no game restart, no bridge restart.

Files (later wins):
  1. the built-in text in alifetalk_bridge.py (always there; a missing file or section falls back to it)
  2. bridge\\prompts.txt              shipped with the mod (a mod update may replace it)
  3. Zomboid\\Lua\\alifeai_prompts.txt  YOURS: survives mod updates. Copy a section here and change it.

Format: a [SECTION] line, then its text, until the next [SECTION]. Lines starting with "# " are comments.
  [STATIC_HEAD]            one block of text
  [STANCE.hostile]         one entry of a table
  [MUST_LINES.taunt]       a list: one line each
  [DRUNK_STYLE.2]          one entry of a list, by number (0 = first)
  [extra]                  added to the end of EVERY prompt (your house rules)
  [mode.reply]             added only for that kind of line (reply, ambient, chime, banter, react, ...)
Placeholders like {name} are NOT filled in these files: write plain text.
"""
import copy
import os
import re

# a section line: [NAME] or [NAME.entry] (entries may have spaces: [TIER_TONE.close friend]), at the start of the line
_SEC = re.compile(r"^\[([A-Za-z_][A-Za-z0-9_]*(?:\.[^\[\]]+)?)\]$")

NAMES = ["STATIC_HEAD", "STANCE", "DRUNK_STYLE", "MUST_LINES", "MUST_LINES_DARK", "PAIR_JSON", "TIER_TONE",
         "FEW_SHOT_AMBIENT", "FEW_SHOT_REPLY", "LAST_HOW", "ASKBACK_HOW", "FALLBACK_LINES", "LENGTHS", "CALM_LENGTH"]
USER_FILE = "alifeai_prompts.txt"
SHIPPED_FILE = "prompts.txt"

_state = {"defaults": None, "mtimes": None, "extra": "", "modes": {}, "applied": 0, "errors": []}


def parse(text):
    """text -> {section: text} (order kept)."""
    out, cur, buf = {}, None, []
    for raw in (text or "").replace("\r\n", "\n").split("\n"):
        line = raw.rstrip()
        if line.startswith("# ") or line == "#":
            continue
        m = _SEC.match(line.strip())
        if m and line == line.lstrip():
            if cur is not None:
                out[cur] = "\n".join(buf).strip("\n")
            cur, buf = m.group(1), []
        elif cur is not None:
            buf.append(line)
    if cur is not None:
        out[cur] = "\n".join(buf).strip("\n")
    return out


def capture(mod):
    if _state["defaults"] is None:
        _state["defaults"] = {n: copy.deepcopy(getattr(mod, n)) for n in NAMES if hasattr(mod, n)}
    return _state["defaults"]


def _key_of(table, sub):
    """the real key in a table for a section's sub part ("1" -> 1 when the table uses numbers)."""
    if isinstance(table, list):
        try:
            return int(sub)
        except ValueError:
            return None
    if sub in table:
        return sub
    try:
        n = int(sub)
        if n in table:
            return n
    except ValueError:
        pass
    return sub  # a new entry in a dict is allowed


def apply(mod, sections):
    """put defaults back, then every section on top. Returns how many sections were used."""
    defaults = capture(mod)
    fresh = {n: copy.deepcopy(v) for n, v in defaults.items()}
    used, extra, modes, errors = 0, [], {}, []
    for sec, text in sections.items():
        if sec == "extra":
            if text.strip():
                extra.append(text.strip())
            used += 1
            continue
        if sec.startswith("mode."):
            if text.strip():
                modes[sec[5:]] = (modes.get(sec[5:], "") + "\n" + text.strip()).strip()
            used += 1
            continue
        name, _, sub = sec.partition(".")
        if name not in fresh:
            errors.append("unknown section [%s]" % sec)
            continue
        cur = fresh[name]
        if not sub:
            if isinstance(cur, str):
                fresh[name] = text
                used += 1
            else:
                errors.append("[%s] is a table: use [%s.<entry>]" % (sec, name))
            continue
        if not isinstance(cur, (list, dict)):
            errors.append("[%s]: %s is one block of text, use [%s]" % (sec, name, name))
            continue
        key = _key_of(cur, sub)
        if key is None or (isinstance(cur, list) and not (0 <= key < len(cur))):
            errors.append("[%s]: no such entry" % sec)
            continue
        old = cur[key] if (isinstance(cur, list) or key in cur) else None
        if isinstance(old, list) or (old is None and isinstance(cur, dict) and cur and isinstance(next(iter(cur.values())), list)):
            cur[key] = [x.strip() for x in text.split("\n") if x.strip()]
        else:
            cur[key] = text
        used += 1
    for n, v in fresh.items():
        setattr(mod, n, v)
    _state["extra"], _state["modes"], _state["applied"], _state["errors"] = "\n".join(extra), modes, used, errors
    return used


def files(lua_dir, bridge_dir=None):
    bridge_dir = bridge_dir or os.path.dirname(os.path.abspath(__file__))
    return [os.path.join(bridge_dir, SHIPPED_FILE), os.path.join(lua_dir or "", USER_FILE)]


def refresh(mod, lua_dir, bridge_dir=None, log=None):
    """re-read the files when one changed (cheap: two stat calls). True when it re-applied."""
    paths = files(lua_dir, bridge_dir)
    mt = []
    for p in paths:
        try:
            mt.append(os.path.getmtime(p))
        except OSError:
            mt.append(None)
    if mt == _state["mtimes"]:
        return False
    _state["mtimes"] = mt
    sections = {}
    for p in paths:
        try:
            with open(p, "r", encoding="utf-8-sig") as f:
                for k, v in parse(f.read()).items():
                    if k == "extra" and k in sections:
                        v = sections[k] + "\n" + v
                    sections[k] = v
        except OSError:
            pass
    n = apply(mod, sections)
    if log is not None:
        log("prompts: %d section(s) from %s" % (n, ", ".join(os.path.basename(p) for p, m in zip(paths, mt) if m is not None) or "built-in only"))
        for e in _state["errors"][:5]:
            log("prompts: " + e)
    return True


def extra_for(mode):
    parts = [x for x in (_state["extra"], _state["modes"].get(mode or "reply", "")) if x]
    return "\n".join(parts)


def dump(mod):
    """the built-in text as a prompts file (what bridge\\prompts.txt starts as)."""
    d = capture(mod)
    out = [x if x else "#" for x in ("# " + l if l else "" for l in __doc__.strip().split("\n"))]
    out.append("")
    for n in NAMES:
        v = d.get(n)
        if isinstance(v, str):
            out += ["[%s]" % n, v, ""]
        elif isinstance(v, dict):
            for k, x in v.items():
                out.append("[%s.%s]" % (n, k))
                out += (list(x) if isinstance(x, (list, tuple)) else [str(x)])
                out.append("")
        elif isinstance(v, list):
            for i, x in enumerate(v):
                out += ["[%s.%d]" % (n, i), str(x), ""]
    out += ["[extra]", "", "[mode.reply]", ""]
    return "\n".join(out) + "\n"
