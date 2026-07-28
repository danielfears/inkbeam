@echo off
setlocal
title Uninstall InkBeam
echo This removes the receiver, widget, settings, pairing data and firewall rules.
set /p "confirm=Continue? [y/N] "
if /I not "%confirm%"=="Y" exit /b 0
cd /d "%TEMP%"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" ^
  -NoProfile -ExecutionPolicy Bypass ^
  -File "%~dp0uninstall.ps1"
set "exitCode=%ERRORLEVEL%"
echo.
if not "%exitCode%"=="0" (
  echo InkBeam uninstallation failed with exit code %exitCode%.
) else (
  echo InkBeam uninstallation complete.
)
pause
exit /b %exitCode%
