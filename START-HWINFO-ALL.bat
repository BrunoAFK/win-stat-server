@echo off
title HWiNFO All Sensors Web Bridge
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0hwinfo-all-web.ps1" -Port 8080
echo.
pause
