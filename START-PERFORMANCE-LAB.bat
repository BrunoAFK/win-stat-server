@echo off
title Win Stat Server v8.0
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0hwinfo-performance-lab.ps1" -Port 8080
echo.
pause
