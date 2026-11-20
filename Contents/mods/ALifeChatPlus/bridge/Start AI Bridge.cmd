@echo off
title A-Life AI Bridge
set /p MODEL=<"%~dp0model.txt"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0alifeai_bridge.ps1" -Model %MODEL%
pause
