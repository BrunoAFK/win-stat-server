@echo off
title HWiNFO Performance Lab v6.9
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0hwinfo-performance-lab.ps1" -Port 8080
echo.
pause
