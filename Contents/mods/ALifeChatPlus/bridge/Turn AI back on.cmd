@echo off
title Turn A-Life AI back on
del "%USERPROFILE%\Zomboid\Lua\alifeai_off.flag" >nul 2>&1
echo The AI switch is ON. The helper starts the AI within a few seconds (while the game is open).
echo If the helper is not running, run "Restart AI helper.cmd".
timeout /t 5 >nul
