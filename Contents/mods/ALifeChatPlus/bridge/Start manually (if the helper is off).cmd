@echo off
set /p MODEL=<"%~dp0model.txt"
start "A-Life AI Bridge" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0alifeai_bridge.ps1" -Model %MODEL%
start "A-Life Voice" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0alifeai_whisper.ps1"
