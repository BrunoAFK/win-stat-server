@echo off
title HWiNFO All Sensors Web Bridge v2.1
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0hwinfo-all-web.ps1" -Port 8080
echo.
pause
