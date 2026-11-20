@echo off
title Restart A-Life AI helper
echo Stopping any old copy of the helper and starting the current one...
del "%USERPROFILE%\Zomboid\Lua\alifeai_off.flag" >nul 2>&1
wscript.exe "%~dp0alifeai_hidden.vbs"
echo Done. If the game still says the helper is not running, send Zomboid\Lua\alifeai_helper_log.txt
timeout /t 6 >nul
