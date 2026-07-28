@echo off
setlocal
title Install InkBeam
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" ^
  -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
set "exitCode=%ERRORLEVEL%"
echo.
if not "%exitCode%"=="0" (
  echo InkBeam installation failed with exit code %exitCode%.
) else (
  echo InkBeam installation complete.
)
pause
exit /b %exitCode%
