' Starts the A-Life Chat Plus helper with no window. It waits for Project Zomboid, then starts the AI and voice.
Set sh = CreateObject("WScript.Shell")
dir = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
sh.Run "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & dir & "\alifeai_watcher.ps1""", 0, False
