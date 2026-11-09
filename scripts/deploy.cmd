@echo off
rem One-click deploy: double-click this file (UAC will be requested once).
chcp 65001 >nul 2>&1
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy-local.ps1" %*
set RC=%ERRORLEVEL%
echo.
if not "%RC%"=="0" echo Deploy failed with exit code %RC%.
pause
exit /b %RC%
