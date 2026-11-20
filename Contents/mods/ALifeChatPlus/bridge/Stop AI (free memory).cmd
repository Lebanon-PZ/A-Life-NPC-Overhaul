@echo off
title Stop A-Life AI
rem Turns the AI OFF and keeps it off (the helper would otherwise start it again while the game is open).
rem To turn it back on: "Turn AI back on.cmd" (or the AI tab in the game).
if not exist "%USERPROFILE%\Zomboid\Lua" mkdir "%USERPROFILE%\Zomboid\Lua"
echo AI is off. Delete this file or run "Turn AI back on.cmd" to turn it on.>"%USERPROFILE%\Zomboid\Lua\alifeai_off.flag"
set /p MODEL=<"%~dp0model.txt"
ollama stop %MODEL% >nul 2>&1
taskkill /IM whisper-server.exe /F >nul 2>&1
powershell -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'alifeai_bridge\.ps1|alifeai_whisper\.ps1|alifeai_voice\.ps1|alifetalk_bridge\.py' -and $_.ProcessId -ne $PID } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }"
echo Done. The AI is OFF and memory is freed. It stays off until you run "Turn AI back on.cmd".
timeout /t 4 >nul
