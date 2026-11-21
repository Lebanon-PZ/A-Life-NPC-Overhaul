@echo off
title Remove A-Life AI helper
rem Run this BEFORE you unsubscribe. Removes the startup shortcut and stops every helper process.
del /f /q "%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\A-Life Chat Plus helper.lnk" >nul 2>&1
powershell -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'alifeai_|alifetalk_' -and $_.ProcessId -ne $PID } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }"
taskkill /IM whisper-server.exe /F >nul 2>&1
echo Done. The helper will no longer start with Windows. You can unsubscribe now.
timeout /t 5 >nul
