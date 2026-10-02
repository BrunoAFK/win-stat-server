@echo off
title HWiNFO Web Bridge
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0hwinfo-web.ps1" -Port 8080
pause
