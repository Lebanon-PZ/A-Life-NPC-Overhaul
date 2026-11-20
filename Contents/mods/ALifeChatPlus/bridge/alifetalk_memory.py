"""
A-Life Talk persistent memory (stdlib only).

One JSON file per NPC, per world/save:
    <Zomboid>/Lua/alifetalk_mem/<world id>/<sanitized A-Life uid>.json

{
  "v": 1, "uid": "palife:...", "name": "Ann Ellis", "world": "...",
  "summary": "rolling summary of older history (<= ~70 words)",
  "facts": ["short key facts", ...],            # <= 10
  "folded": 37,                                  # entries already folded into summary/facts
  "total": 120,                                  # entries ever written
  "entries": [                                   # newest last, capped at MAX_ENTRIES
    {"k": "talk",  "d": 12, "tm": "14:05", "ts": 1760000000, "p": "player line", "r": "npc reply", "act": "WALK_WITH_ME"},
    {"k": "line",  "d": 12, "tm": "14:06", "ts": ..., "who": "Bob Kerr", "uid": "palife:..", "x": "what someone said nearby"},
    {"k": "chime", "d": 12, "tm": "14:06", "ts": ..., "who": "Bob Kerr", "uid": "palife:..", "x": "what they said", "r": "my reply"}
  ]
}
"""
import hashlib
import json
import math
import os
import re
import time
import urllib.request


def cosine(a, b):
    if not a or not b or len(a) != len(b):
        return 0.0
    dot = sum(x * y for x, y in zip(a, b))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(y * y for y in b))
    return dot / (na * nb) if na and nb else 0.0


class Embedder:
    """Optional: Ollama /api/embed (e.g. nomic-embed-text). Vectors cached on disk; the query gets a short deadline so
    a slow embed never delays a reply (keyword retrieval is used instead)."""

    def __init__(self, ollama_url, model, cache_path, query_timeout=1.5):
        self.url = ollama_url.rstrip("/")
        self.model = model
        self.path = cache_path
        self.qt = query_timeout
        self.vecs = {}
        self.dirty = False
        self.failed_until = 0
        try:
            with open(cache_path, "r", encoding="utf-8") as f:
                self.vecs = json.load(f)
        except Exception:
            self.vecs = {}

    @staticmethod
    def key(text):
        return hashlib.sha1(text.encode("utf-8")).hexdigest()[:16]

    def cached(self, text):
        return self.vecs.get(self.key(text))

    def _embed(self, text, timeout):
        if time.time() < self.failed_until:
            return None
        body = json.dumps({"model": self.model, "input": text}).encode("utf-8")
        req = urllib.request.Request(self.url + "/api/embed", data=body, headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                out = json.loads(r.read().decode("utf-8"))
            v = (out.get("embeddings") or [None])[0]
            return [round(float(x), 5) for x in v] if v else None
        except Exception:
            self.failed_until = time.time() + 60
            return None

    def query(self, text):
        return self._embed(text, self.qt)

    def embed_store(self, text):
        v = self._embed(text, 10)
        if v is None:
            return False
        self.vecs[self.key(text)] = v
        if len(self.vecs) > 6000:
            for k in list(self.vecs)[:1000]:
                del self.vecs[k]
        self.dirty = True
        return True

    def save(self):
        if not self.dirty:
            return
        tmp = self.path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(self.vecs, f)
        os.replace(tmp, self.path)
        self.dirty = False

MAX_ENTRIES = 200      # hard cap per NPC file
KEEP_AFTER_TRIM = 150  # trim down to this many when the cap is hit
FOLD_EVERY = 30        # unfolded entries older than the verbatim window before a background summary runs
VERBATIM_TALKS = 6     # last exchanges with the player quoted word for word
SHARED_LINES = 4       # last lines involving NPCs who are here now
HEARD_LINES = 3  # v3.2: overheard lines shown in the prompt
MAX_FACTS = 10
SUMMARY_CHARS = 480
DEDUPE_WINDOW = 40     # recent entries checked so a heard line is stored once
# v0.5.0 smarter memory: every entry gets an importance score (1-10); trimming keeps the important ones as
# "keepsakes"; each prompt retrieves the 3 older memories most relevant to what is happening now
# (keyword overlap x importance x recency; optional embeddings through Ollama, e.g. nomic-embed-text).
KEEPSAKES = 24
RECALL_TOP = 3
KIND_IMP = {"event": 5, "gift": 5, "talk": 3, "heard": 3, "line": 2, "chime": 1}
IMP_WORDS = {
    9: r"\b(killed|murder|died|dead|death|betray\w*|nemesis|revenge|love you|marry|partner|saved my life)\b",
    7: r"\b(promise\w*|secret|family|wife|husband|son|daughter|mother|father|brother|sister|bit|bitten|infected|"
       r"attack\w*|shot|stab\w*|rob\w*|stole|steal|lied|lie|trap|ambush|hate|crush|kiss)\b",
    5: r"\b(gift|gave|food|water|medicine|bandage|ammo|gun|help\w*|thank\w*|sorry|camp|home|job|quest|rumou?r|war|truce)\b",
}
STOP = set("a an the and or but if to of in on at for with is are was were be been it its this that you your i me my "
           "we our they them their he she his her not no yes do did does have has had what who where when why how "
           "just so up out about from as by can could would will shall should there here then than too very".split())


def importance(entry):
    """1..10: how much this moment would stick with a person."""
    k = entry.get("k")
    base = KIND_IMP.get(k, 2)
    text = " ".join(str(entry.get(f) or "") for f in ("p", "r", "x", "what", "items", "kind")).lower()
    for score, rx in sorted(IMP_WORDS.items(), reverse=True):
        if re.search(rx, text):
            base = max(base, score)
            break
    try:
        base += min(3, abs(int(entry.get("dv") or 0)) // 3)
    except (TypeError, ValueError):
        pass
    if entry.get("about") or entry.get("rude"):
        base += 1
    return max(1, min(10, base))


def words_of(text):
    return set(w for w in re.findall(r"[a-z']{3,}", str(text or "").lower()) if w not in STOP)


def entry_text(e):
    k = e.get("k")
    if k == "talk":
        return f"they said \"{_one(e.get('p'), 120)}\", you said \"{_one(e.get('r'), 120)}\""
    if k == "gift":
        return f"they gave you {_one(e.get('items'), 80)}"
    if k == "event":
        return _one(e.get("what") or e.get("x"), 160)
    if k == "heard":
        return f"you overheard them say \"{_one(e.get('x'), 120)}\""
    who = "you" if e.get("who") == "self" else _one(e.get("who"), 30)
    return f"{who} said \"{_one(e.get('x'), 120)}\""


def sanitize(value, limit=80):
    s = re.sub(r"[^A-Za-z0-9_.-]+", "_", str(value or "").strip())[:limit].strip("._")
    return s or "unknown"


def _one(s, n=200):
    return re.sub(r"\s+", " ", str(s or "")).strip()[:n]


def _when(req):
    w = req.get("world") or {}
    day = w.get("day") if isinstance(w.get("day"), (int, float)) else 0
    h = w.get("hour") if isinstance(w.get("hour"), (int, float)) else 0
    m = w.get("minute") if isinstance(w.get("minute"), (int, float)) else 0
    return int(day), f"{int(h):02d}:{int(m):02d}"


class Memory:
    def __init__(self, root):
        self.root = root
        self.cache = {}       # path -> data
        self.dirty = set()
        self.todo = set()     # paths that need a background summary
        self.embedder = None  # v0.5.0: optional Embedder (--embed-model)

    # ---------------------------------------------------------------- files
    def path(self, world, uid):
        return os.path.join(self.root, sanitize(world or "default"), sanitize(uid) + ".json")

    def load(self, world, uid, name=None):
        p = self.path(world, uid)
        data = self.cache.get(p)
        if data is None:
            try:
                with open(p, "r", encoding="utf-8") as f:
                    data = json.load(f)
            except (FileNotFoundError, json.JSONDecodeError, OSError):
                data = None
            if not isinstance(data, dict) or not isinstance(data.get("entries"), list):
                data = {"v": 1, "uid": str(uid), "world": str(world or "default"), "name": name or "",
                        "summary": "", "facts": [], "folded": 0, "total": 0, "entries": []}
            self.cache[p] = data
        if name and not data.get("name"):
            data["name"] = name
        return p, data

    def save(self, p=None):
        for path in ([p] if p else list(self.dirty)):
            data = self.cache.get(path)
            if data is None:
                continue
            os.makedirs(os.path.dirname(path), exist_ok=True)
            tmp = path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(data, f, ensure_ascii=False, separators=(",", ":"))
            os.replace(tmp, path)
            self.dirty.discard(path)

    # ---------------------------------------------------------------- writing
    def _add(self, p, data, entry):
        if "imp" not in entry:
            entry["imp"] = importance(entry)
        data["entries"].append(entry)
        data["total"] = int(data.get("total") or 0) + 1
        self.dirty.add(p)
        n = len(data["entries"])
        if n - int(data.get("folded") or 0) - VERBATIM_TALKS * 2 >= FOLD_EVERY:
            self.todo.add(p)
        if n > MAX_ENTRIES:
            self.trim(p, data)

    def trim(self, p, data):
        """Cap reached: fold the oldest entries (cheap text fold if the model has not summarized them yet)."""
        cut = len(data["entries"]) - KEEP_AFTER_TRIM
        folded = int(data.get("folded") or 0)
        if folded < cut:
            self.fold_cheap(data, data["entries"][folded:cut])
            folded = cut
        # v0.5.0: the important moments survive the trim as keepsakes (retrievable later)
        keep = data.get("keep") or []
        for e in data["entries"][:cut]:
            if int(e.get("imp") or importance(e)) >= 7:
                keep.append({"d": e.get("d"), "ts": e.get("ts"), "imp": int(e.get("imp") or importance(e)), "t": entry_text(e)})
        keep.sort(key=lambda e: (e.get("imp") or 0, e.get("ts") or 0))
        data["keep"] = keep[-KEEPSAKES:]
        data["entries"] = data["entries"][cut:]
        data["folded"] = max(0, folded - cut)
        self.dirty.add(p)

    # ---------------------------------------------------------------- v0.4.0: interaction log + backstory
    MAX_INTERACTIONS = 100

    def add_interactions(self, world, uid, name, rows):
        """Per-NPC interaction log from the game (date/time, what happened, opinion before->after, mood change)."""
        if not uid or not rows:
            return 0
        p, data = self.load(world, uid, name)
        log_ = data.setdefault("interactions", [])
        seen = {(r.get("t"), r.get("w")) for r in log_[-30:] if isinstance(r, dict)}
        n = 0
        for r in rows:
            if not isinstance(r, dict):
                continue
            row = {k: (_one(r[k], 160) if isinstance(r[k], str) else r[k]) for k in ("t", "w", "a", "b", "m1", "m2", "k")
                   if k in r and r[k] is not None}
            if (row.get("t"), row.get("w")) in seen:
                continue
            log_.append(row)
            n += 1
        del log_[:-self.MAX_INTERACTIONS]
        if n:
            self.dirty.add(p)
        return n

    def forget_interactions(self, world, uid, whats):
        """0.5.2.5: drop interaction rows the game removed (e.g. "Heard X's last words" for someone who lived)."""
        whats = {_one(w, 160) for w in (whats or []) if isinstance(w, str)}
        if not uid or not whats:
            return 0
        p, data = self.load(world, uid)
        log_ = data.get("interactions") or []
        keep = [r for r in log_ if not (isinstance(r, dict) and r.get("w") in whats)]
        n = len(log_) - len(keep)
        if n:
            data["interactions"] = keep
            self.dirty.add(p)
        return n

    def story_of(self, world, uid):
        _, data = self.load(world, uid)
        st = data.get("story")
        return st if isinstance(st, dict) and st.get("bits") else None

    def set_story(self, world, uid, bits, src):
        p, data = self.load(world, uid)
        data["story"] = {"bits": [_one(b, 220) for b in bits if b][:4], "src": src, "ts": int(time.time())}
        self.dirty.add(p)
        self.save(p)
        return data["story"]

    def seen(self, data, uid, text):
        for e in data["entries"][-DEDUPE_WINDOW:]:
            if e.get("x") == text and e.get("uid") == uid:
                return True
            if e.get("k") == "talk" and (e.get("r") == text or e.get("p") == text):
                return True
            if e.get("k") == "chime" and e.get("r") == text:
                return True
        return False

    def record_event(self, req):  # noqa: C901
        """Something an NPC saw (fire, horde, bodies, wreck, a death): stored in every witness's file, deduped."""
        ev = req.get("event") or {}
        world = req.get("worldId")
        day, tm = _when(req)
        entry = {"k": "event", "d": day, "tm": tm, "ts": int(time.time())}
        for key in ("kind", "what", "where", "x", "y", "killer", "killerUid", "victim", "victimUid"):
            if ev.get(key) not in (None, ""):
                entry[key] = ev[key] if isinstance(ev[key], (int, float)) else _one(ev[key], 120)
        for wuid in ev.get("witnesses") or []:
            p, data = self.load(world, wuid)
            dup = False
            for e in data["entries"][-DEDUPE_WINDOW:]:
                if e.get("k") != "event" or e.get("kind") != entry.get("kind"):
                    continue
                if entry.get("victimUid") and e.get("victimUid") == entry.get("victimUid"):
                    dup = True
                elif (not entry.get("victimUid") and e.get("d") == day and isinstance(e.get("x"), (int, float))
                      and isinstance(entry.get("x"), (int, float)) and abs(e["x"] - entry["x"]) < 15
                      and abs(e.get("y", 0) - entry.get("y", 0)) < 15):
                    dup = True
            if not dup:
                self._add(p, data, dict(entry))
        self.save()

    def record(self, req, result):
        """Store one finished exchange (and the lines heard nearby) in every NPC file it concerns."""
        uid = req.get("uid")
        world = req.get("worldId")
        if req.get("mode") == "event":
            self.record_event(req)
            return
        if req.get("mode") == "hear":  # v3.2: the newcomer said this within earshot (not to them)
            h = req.get("hear") or {}
            day, tm = _when(req)
            for l in (h.get("listeners") or [])[:8]:
                if not isinstance(l, dict) or not l.get("uid"):
                    continue
                p, data = self.load(world, l["uid"], _one(l.get("name"), 40))
                entry = {"k": "heard", "d": day, "tm": tm, "ts": int(time.time()), "x": _one(req.get("said"), 200)}
                if l.get("named"):
                    entry["about"] = True
                if result and int(result.get("d") or 0) < 0:
                    entry["rude"] = True
                if h.get("loud"):
                    entry["loud"] = True
                self._add(p, data, entry)
            self.save()
            return
        if not uid or result is None:
            return
        npc = req.get("npc") or {}
        me_name = _one(npc.get("name"), 40) or "NPC"
        p, data = self.load(world, uid, me_name)
        day, tm = _when(req)
        ts = int(time.time())
        mode = req.get("mode") or "reply"
        say = _one(result.get("say"), 240)
        # lines said nearby (A-Life canned replies, scripted banter, other NPCs, the player to others)
        for h in req.get("heard") or []:
            if not isinstance(h, list) or len(h) < 2:
                continue
            who, text = _one(re.sub(r"\s*\(.*?\)", "", str(h[0])), 40), _one(h[1], 240)
            huid = h[2] if len(h) > 2 and h[2] else ("player" if who == "Them" else "")
            if not text or text == "..." or self.seen(data, huid, text):
                continue
            if who == "Them" and text == _one(req.get("said"), 240):
                continue  # stored with the talk entry below
            who = "self" if who == "You" else ("player" if who == "Them" else who)
            self._add(p, data, {"k": "line", "d": day, "tm": tm, "ts": ts, "who": who,
                                "uid": huid, "x": text})
        if mode in ("gift", "note"):
            g = req.get("gift") or {}
            names = ", ".join(_one(i.get("name"), 50) for i in (g.get("items") or []) if isinstance(i, dict))
            entry = {"k": "gift", "d": day, "tm": tm, "ts": ts, "items": names or "something", "r": say}
            if g.get("trade"):
                entry["trade"] = ", ".join(_one(x, 40) for x in (g.get("received") or [])) or True
            if result.get("act") == "DRINK":
                entry["act"] = "DRINK"
            if mode == "note":
                entry["via"] = "A-Life"
            self._add(p, data, entry)
        elif mode in ("death", "sound", "grief", "injury", "injury_self", "taunt", "news", "follow", "calm", "warn", "nemesis"):
            if say:
                self._add(p, data, {"k": "line", "d": day, "tm": tm, "ts": ts, "who": "self", "uid": uid, "x": say})
        elif mode == "ambient":
            if say:
                partner = req.get("partner") or {}
                puid, pname = req.get("speakerUid") or partner.get("uid") or "", _one(partner.get("name"), 40) or "someone"
                self._add(p, data, {"k": "line", "d": day, "tm": tm, "ts": ts, "who": "self", "uid": uid, "x": say,
                                    "to": pname, "toUid": puid})
                if puid:
                    op, odata = self.load(world, puid, pname)
                    self._add(op, odata, {"k": "line", "d": day, "tm": tm, "ts": ts, "who": me_name, "uid": uid,
                                          "x": say, "to": "you"})
        elif mode in ("reply", "radio"):
            entry = {"k": "talk", "d": day, "tm": tm, "ts": ts, "p": _one(req.get("said"), 240), "r": say}
            if mode == "radio":
                entry["radio"] = True
            if result.get("act") not in (None, "", "NONE"):
                entry["act"] = result["act"]
            self._add(p, data, entry)
        elif say:
            line = req.get("line") or ["someone", ""]
            other_uid = req.get("speakerUid") or ""
            other_name = _one(re.sub(r"\s*\(.*?\)", "", str(line[0])), 40)
            if other_name == "Them":
                other_name, other_uid = "player", "player"
            self._add(p, data, {"k": "chime", "d": day, "tm": tm, "ts": ts, "who": other_name, "uid": other_uid,
                                "x": _one(line[1], 240), "r": say})
            if other_uid and other_uid != "player":  # the other NPC remembers my answer too
                op, odata = self.load(world, other_uid, other_name)
                if not self.seen(odata, other_uid, _one(line[1], 240)):
                    self._add(op, odata, {"k": "line", "d": day, "tm": tm, "ts": ts, "who": "self", "uid": other_uid,
                                          "x": _one(line[1], 240)})
                self._add(op, odata, {"k": "line", "d": day, "tm": tm, "ts": ts, "who": me_name, "uid": uid, "x": say})
        self.save()

    # ---------------------------------------------------------------- prompt
    def prompt_block(self, req):
        uid = req.get("uid")
        if not uid:
            return ""
        p, data = self.load(req.get("worldId"), uid, _one((req.get("npc") or {}).get("name"), 40))
        entries = data["entries"]
        out = []
        if data.get("summary"):
            out.append("What you remember from before: " + _one(data["summary"], SUMMARY_CHARS))
        if data.get("facts"):
            out.append("Key facts: " + "; ".join(_one(f, 90) for f in data["facts"][:MAX_FACTS]) + ".")
        talks = [e for e in entries if e.get("k") in ("talk", "gift")][-VERBATIM_TALKS:]
        if talks:
            out.append("Your past talks with this person (oldest first):\n" + "\n".join(map(self.fmt_talk, talks)))
        present = set(x for x in (req.get("presentUids") or []) if x)
        if req.get("speakerUid"):
            present.add(req["speakerUid"])
        shared = [e for e in entries if e.get("k") in ("line", "chime")
                  and (e.get("uid") in present or e.get("toUid") in present)][-SHARED_LINES:]
        if shared:
            def fmt(e):
                if e["k"] == "chime":
                    return f"[day {e.get('d')} {e.get('tm')}] {e.get('who')}: \"{_one(e.get('x'), 100)}\" / You: \"{_one(e.get('r'), 100)}\""
                who = "You" if e.get("who") == "self" else e.get("who")
                to = f" (to {e['to']})" if e.get("to") and e.get("to") != "you" else ""
                return f"[day {e.get('d')} {e.get('tm')}] {who}{to}: \"{_one(e.get('x'), 120)}\""
            out.append("Earlier with the people here now:\n" + "\n".join(fmt(e) for e in shared))
        heard = [e for e in entries if e.get("k") == "heard"][-HEARD_LINES:]
        if heard:
            out.append("Things you overheard the newcomer say (not to you):\n" + "\n".join(
                f"[day {e.get('d')} {e.get('tm')}]{' (shouted)' if e.get('loud') else ''} \"{_one(e.get('x'), 120)}\""
                + (" - about YOU" if e.get("about") else "") + (" (rude)" if e.get("rude") else "") for e in heard)
                + "\nYou may bring it up (\"I heard what you said about me\").")
        evs = self.events_block(entries, req)
        if evs:
            out.append(evs)
        shown = set(id(e) for e in talks) | set(id(e) for e in shared) | set(id(e) for e in heard)
        recall = self.recall(data, req, skip=shown)
        if recall:
            out.append("This brings back older memories (use only if it fits):\n" + "\n".join(
                f"[day {r.get('d')}] {r['t']}" for r in recall))
        if out:
            out.append("If something came up before, you may naturally refer back to it "
                       "(\"you asked me that already\", \"last time you said...\"). Don't recite these notes.")
        return "\n".join(out)

    @staticmethod
    def query_of(req):
        bits = [req.get("said") or "", (req.get("react") or {}).get("what") or "", (req.get("event") or {}).get("what") or ""]
        line = req.get("line")
        if isinstance(line, list) and len(line) > 1:
            bits.append(str(line[1]))
        q = req.get("quest") or {}
        if isinstance(q, dict):
            bits.extend(str(v) for v in q.values() if isinstance(v, str))
        return " ".join(str(b) for b in bits)

    def recall(self, data, req, skip=(), top=RECALL_TOP):
        """Older memories most relevant to now: keyword overlap (or embedding similarity) x importance x recency."""
        query = self.query_of(req)
        qw = words_of(query)
        if not qw:
            return []
        now = time.time()
        cands = []
        entries = data.get("entries") or []
        recent_cut = max(0, len(entries) - VERBATIM_TALKS * 2)
        for i, e in enumerate(entries[:recent_cut]):
            if id(e) in skip:
                continue
            cands.append({"d": e.get("d"), "ts": e.get("ts"), "imp": int(e.get("imp") or importance(e)), "t": entry_text(e)})
        cands.extend(dict(k) for k in (data.get("keep") or []))
        qvec = self.embed_query(query) if self.embedder is not None else None
        scored = []
        seen = set()
        for c in cands:
            if c["t"] in seen:
                continue
            seen.add(c["t"])
            sim = 0.0
            if qvec is not None:
                v = self.embedder.cached(c["t"])
                if v is not None:
                    sim = max(0.0, cosine(qvec, v) - 0.45) * 4
            if sim == 0.0:
                cw = words_of(c["t"])
                ov = len(qw & cw)
                if ov == 0:
                    continue
                sim = ov / (len(qw) ** 0.5 * max(1, len(cw)) ** 0.5)
            age_days = max(0.0, (now - float(c.get("ts") or now)) / 86400.0)
            score = sim * (0.5 + c["imp"] / 10.0) * (1.0 / (1.0 + age_days / 30.0))
            if score > 0.05:
                scored.append((score, c))
        scored.sort(key=lambda x: -x[0])
        return [c for _, c in scored[:top]]

    def embed_query(self, query):
        try:
            return self.embedder.query(query)
        except Exception:
            return None

    def embed_idle(self, budget=8):
        """Background: embed memory texts not yet embedded (only when an embedder is configured)."""
        if self.embedder is None:
            return 0
        n = 0
        for p, data in list(self.cache.items()):
            for e in (data.get("entries") or [])[-60:]:
                if n >= budget:
                    return n
                if self.embedder.cached(entry_text(e)) is None and self.embedder.embed_store(entry_text(e)):
                    n += 1
            for k in data.get("keep") or []:
                if n >= budget:
                    return n
                if self.embedder.cached(k["t"]) is None and self.embedder.embed_store(k["t"]):
                    n += 1
        return n

    @staticmethod
    def events_block(entries, req):
        w = req.get("world") or {}
        today = w.get("day") if isinstance(w.get("day"), (int, float)) else None
        pos = req.get("pos") if isinstance(req.get("pos"), list) and len(req.get("pos")) >= 2 else None
        events = [e for e in entries if e.get("k") == "event"]
        deaths = [e for e in events if e.get("kind") == "death"][-3:]
        recent = [e for e in events if e.get("kind") != "death"
                  and (today is None or not isinstance(e.get("d"), (int, float)) or today - e["d"] <= 2)][-3:]
        lines = []
        for e in sorted(deaths + recent, key=lambda e: e.get("ts") or 0):
            when = f"day {e.get('d')} {e.get('tm')}"
            if today is not None and e.get("d") == today:
                when = f"earlier today ({e.get('tm')})"
            where = e.get("where") or ""
            where = (" " + where if where.startswith("near ") else f" at {where}") if where else ""
            rel = ""
            if pos and isinstance(e.get("x"), (int, float)) and isinstance(e.get("y"), (int, float)):
                rel = " " + Memory.direction(e["x"] - pos[0], e["y"] - pos[1])
            what = e.get("what") or e.get("kind")
            if e.get("kind") == "death" and e.get("killerUid") == "player":
                what = f"{e.get('victim')} was killed by the person talking to you (you saw it)"
            lines.append(f"- {when}: {what}{where}{rel}")
        if not lines:
            return ""
        return "Things you saw (they color your mood; bring them up if it fits; a bite is deadly serious):\n" + "\n".join(lines)

    @staticmethod
    def direction(dx, dy):
        d = (dx * dx + dy * dy) ** 0.5
        if d < 8:
            return "(right around here)"
        import math
        ang = math.degrees(math.atan2(-dy, dx)) % 360  # map y grows south
        names = ["east", "northeast", "north", "northwest", "west", "southwest", "south", "southeast"]
        rough = "close by" if d < 40 else "a short walk" if d < 150 else "a good way" if d < 600 else "far"
        return f"({rough}, {names[int((ang + 22.5) // 45) % 8]})"

    @staticmethod
    def fmt_talk(e):
        tag = f"[day {e.get('d')} {e.get('tm')}]"
        if e.get("k") == "gift":
            what = (f"They traded you {_one(e.get('items'), 80)}" if e.get("trade")
                    else f"They gave you {_one(e.get('items'), 80)}")
            if e.get("act") == "DRINK":
                what += " (you drank some)"
            return tag + " " + what + (f" / You: \"{_one(e.get('r'), 100)}\"" if e.get("r") else "")
        return (f"{tag}{' (radio)' if e.get('radio') else ''} They: \"{_one(e.get('p'), 120)}\" / "
                f"You: \"{_one(e.get('r'), 120)}\"")

    # ---------------------------------------------------------------- summaries (run only while the bridge is idle)
    def fold_cheap(self, data, chunk):
        bits = []
        for e in chunk:
            if e.get("k") == "talk" and e.get("p"):
                bits.append(f"day {e.get('d')}: they said \"{_one(e['p'], 60)}\"")
            elif e.get("k") == "gift":
                bits.append(f"day {e.get('d')}: they gave you {_one(e.get('items'), 50)}")
            elif e.get("k") in ("line", "chime") and e.get("who") not in ("self",):
                bits.append(f"day {e.get('d')}: {e.get('who')} said \"{_one(e.get('x'), 50)}\"")
        if bits:
            data["summary"] = _one((data.get("summary", "") + " " + "; ".join(bits[-6:])).strip(), SUMMARY_CHARS * 2)[-SUMMARY_CHARS:]

    def next_job(self):
        while self.todo:
            p = self.todo.pop()
            data = self.cache.get(p)
            if data is None:
                continue
            folded = int(data.get("folded") or 0)
            end = len(data["entries"]) - VERBATIM_TALKS * 2
            if end - folded >= FOLD_EVERY // 2:
                return p, data, folded, end
        return None

    @staticmethod
    def summary_prompt(data, chunk):
        lines = []
        for e in chunk:
            tag = f"[day {e.get('d')} {e.get('tm')}]"
            if e.get("k") == "talk":
                lines.append(f"{tag} Player: {_one(e.get('p'), 160)} | {data.get('name') or 'NPC'}: {_one(e.get('r'), 160)}"
                             + (f" (action {e['act']})" if e.get("act") else ""))
            elif e.get("k") == "event":
                lines.append(f"{tag} Saw: {_one(e.get('what'), 120)}" + (f" at {e['where']}" if e.get("where") else ""))
            elif e.get("k") == "gift":
                lines.append(f"{tag} Player gave {data.get('name') or 'NPC'}: {_one(e.get('items'), 100)}"
                             + (" (trade)" if e.get("trade") else "") + (" - drank some" if e.get("act") else "")
                             + (f" | {data.get('name') or 'NPC'}: {_one(e.get('r'), 120)}" if e.get("r") else ""))
            elif e.get("k") == "chime":
                lines.append(f"{tag} {e.get('who')}: {_one(e.get('x'), 140)} | {data.get('name') or 'NPC'}: {_one(e.get('r'), 140)}")
            else:
                who = (data.get("name") or "NPC") if e.get("who") == "self" else e.get("who")
                lines.append(f"{tag} {who}: {_one(e.get('x'), 160)}")
        system = ("You keep short memory notes for a character in a survival story. Update the notes with the new log. "
                  "summary: max 60 words, third person, what happened between them and the player and other people, oldest "
                  "detail may be dropped. facts: max 8 short concrete facts worth remembering (promises, requests, insults, "
                  "help given, names, plans), each max 12 words, include the day. Return JSON only.")
        user = (f"Character: {data.get('name') or 'NPC'}\nCurrent summary: {data.get('summary') or '(none)'}\n"
                f"Current facts: {'; '.join(data.get('facts') or []) or '(none)'}\nNew log:\n" + "\n".join(lines))
        return [{"role": "system", "content": system}, {"role": "user", "content": user}]

    def apply_summary(self, p, data, end, content):
        try:
            obj = json.loads(content)
        except Exception:
            m = re.search(r"\{.*\}", content or "", re.S)
            obj = json.loads(m.group(0)) if m else {}
        summary = _one(obj.get("summary"), SUMMARY_CHARS) if isinstance(obj, dict) else ""
        facts = obj.get("facts") if isinstance(obj, dict) else None
        if not summary:
            return False
        data["summary"] = summary
        if isinstance(facts, list):
            data["facts"] = [_one(f, 90) for f in facts if isinstance(f, str) and f.strip()][:MAX_FACTS]
        data["folded"] = end
        self.dirty.add(p)
        self.save(p)
        return True


SUMMARY_SCHEMA = {
    "type": "object",
    "properties": {"summary": {"type": "string"}, "facts": {"type": "array", "items": {"type": "string"}}},
    "required": ["summary", "facts"],
}
