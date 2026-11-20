"""A-Life NPC Overhaul 0.6.20: optional automatic bug reports (OFF by default).

When one of the mod's features switches itself off after an error, the game writes it into
<Zomboid>/Lua/ALifeChatPlus_health.txt. If you turn this on, the AI helper sends that report (plus the end of
console.txt) to the address in <Zomboid>/Lua/alifeai_report.txt, so the mod author sees the error without you
having to find and post files.

What is sent: the health report (which features turned off, when, why; how long the mod's handlers take) and the
last lines of console.txt. Your Windows user name and home folder are replaced with <user> / <home> first.
Nothing is sent unless enabled=true AND url= is filled in. At most max_per_day reports a day, and only when the
list of features that turned off has changed since the last report.
"""
import hashlib
import json
import os
import re
import time
import urllib.request

REPORT_FILE = "alifeai_report.txt"
HEALTH_FILE = "ALifeChatPlus_health.txt"
STATE_FILE = "alifeai_report_state.json"
TEMPLATE = """# A-Life NPC Overhaul - AUTOMATIC BUG REPORTS (optional, OFF by default)
# When one of the mod's features switches itself off after an error, the AI helper can send the mod author
# the health report (Zomboid/Lua/ALifeChatPlus_health.txt) and the end of console.txt.
# Your Windows user name and home folder are replaced with <user> / <home> before anything is sent.
# Nothing is sent unless enabled=true and url= is filled in.

enabled=false

# Where reports go (the mod author's report address, from the Workshop page or Discord).
url=

# Lines from the end of console.txt to include (0 = none).
console_lines=300

# At most this many reports a day.
max_per_day=3
"""


def _read_cfg(path):
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
        return None
    return cfg


def off_section(text):
    """The 'features that turned themselves off' block of the health report ('' if none)."""
    m = re.search(r"FEATURES THAT TURNED THEMSELVES OFF\r?\n(.*?)\r?\n\r?\n", text, re.S)
    if not m:
        return ""
    body = m.group(1).strip()
    return "" if body == "none" else body


def scrub(text, home=None, user=None):
    home = home if home is not None else os.path.expanduser("~")
    user = user if user is not None else (os.environ.get("USERNAME") or os.environ.get("USER") or "")
    if home:
        for h in {home, home.replace("\\", "/"), home.replace("/", "\\")}:
            text = text.replace(h, "<home>")
    if user and len(user) >= 3:
        text = re.sub(re.escape(user), "<user>", text, flags=re.I)
    return text


class Reporter:
    def __init__(self, lua_dir, log=print, every=60.0, post=None):
        self.dir = lua_dir
        self.log = log
        self.every = every
        self.next_at = 0.0
        self.post = post or self._post
        self.cfg_path = os.path.join(lua_dir, REPORT_FILE)
        if not os.path.exists(self.cfg_path):
            try:
                with open(self.cfg_path, "w", encoding="utf-8") as f:
                    f.write(TEMPLATE)
            except OSError:
                pass

    def _state(self):
        try:
            with open(os.path.join(self.dir, STATE_FILE), encoding="utf-8") as f:
                return json.load(f)
        except (OSError, ValueError):
            return {}

    def _save(self, st):
        try:
            with open(os.path.join(self.dir, STATE_FILE), "w", encoding="utf-8") as f:
                json.dump(st, f)
        except OSError:
            pass

    def _post(self, url, payload):
        req = urllib.request.Request(url, data=json.dumps(payload).encode("utf-8"),
                                     headers={"Content-Type": "application/json", "User-Agent": "ALifeNPCOverhaul-report"})
        with urllib.request.urlopen(req, timeout=15) as r:
            return 200 <= r.status < 300

    def tick(self, now=None):
        now = time.time() if now is None else now
        if now < self.next_at:
            return None
        self.next_at = now + self.every
        cfg = _read_cfg(self.cfg_path)
        if not cfg or cfg.get("enabled", "false").lower() not in ("true", "yes", "1", "on") or not cfg.get("url"):
            return None
        try:
            with open(os.path.join(self.dir, HEALTH_FILE), encoding="utf-8", errors="replace") as f:
                health = f.read()
        except OSError:
            return None
        offs = off_section(health)
        if not offs:
            return None
        digest = hashlib.sha1(offs.encode("utf-8")).hexdigest()
        st = self._state()
        if st.get("last") == digest:
            return None
        day = time.strftime("%Y-%m-%d", time.localtime(now))
        sent_today = st.get("count", 0) if st.get("day") == day else 0
        try:
            cap = int(cfg.get("max_per_day", "3"))
        except ValueError:
            cap = 3
        if sent_today >= cap:
            return None
        try:
            lines = max(0, int(cfg.get("console_lines", "300")))
        except ValueError:
            lines = 300
        console = ""
        if lines:
            try:
                with open(os.path.join(os.path.dirname(self.dir), "console.txt"), encoding="utf-8", errors="replace") as f:
                    console = "".join(f.readlines()[-lines:])
            except OSError:
                console = ""
        payload = {"kind": "alife-npc-overhaul-health", "health": scrub(health), "console": scrub(console)}
        try:
            ok = self.post(cfg["url"], payload)
        except Exception as e:  # noqa: BLE001 - never let reporting break the helper
            self.log("bug report not sent:", e)
            return False
        if ok:
            st.update({"last": digest, "day": day, "count": sent_today + 1})
            self._save(st)
            self.log("bug report sent (features turned off: %d)" % len(offs.splitlines()))
        return ok
