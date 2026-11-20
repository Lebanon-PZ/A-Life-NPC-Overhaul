#!/usr/bin/env python3
"""A-Life Talk 0.5.0 launcher: starts the bridge (it closes itself when the game closes) and then Project Zomboid
through Steam. Double-click alifetalk_launch.pyw-style or run:  python alifetalk_launch.py [extra bridge options]"""
import os
import subprocess
import sys
import webbrowser

here = os.path.dirname(os.path.abspath(__file__))
cmd = [sys.executable, os.path.join(here, "alifetalk_bridge.py"), "--exit-with-game"] + sys.argv[1:]
flags = getattr(subprocess, "CREATE_NEW_CONSOLE", 0)
subprocess.Popen(cmd, cwd=here, creationflags=flags)
webbrowser.open("steam://rungameid/108600")  # Project Zomboid's Steam app id
