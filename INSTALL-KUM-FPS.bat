@echo off
setlocal
title KUM-FPS Setup

set "SCRIPT=%~dp0INSTALL-KUM-FPS.ps1"

echo.
echo ========================================================================
echo   KUM-FPS ONE-CLICK SETUP
echo ========================================================================
echo.
echo This window will remain open when setup finishes.
echo.

if not exist "%SCRIPT%" (
  echo INSTALL-KUM-FPS.ps1 is not next to this BAT file.
  echo Trying to download it from GitHub...
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
    "Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/BrunoAFK/win-stat-server/v8.0.0/INSTALL-KUM-FPS.ps1' -OutFile '%SCRIPT%'"
)

if not exist "%SCRIPT%" (
  echo.
  echo ERROR: Could not obtain INSTALL-KUM-FPS.ps1
  echo.
  pause
  exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
set "RC=%ERRORLEVEL%"

echo.
echo ========================================================================
if "%RC%"=="0" (
  echo   KUM-FPS SETUP PROCESS FINISHED
) else (
  echo   KUM-FPS SETUP RETURNED ERROR CODE %RC%
)
echo ========================================================================
echo.
echo You can review all output above.
echo Install logs are saved under:
echo   %%LOCALAPPDATA%%\KUM-FPS\logs
echo.
pause
exit /b %RC%
