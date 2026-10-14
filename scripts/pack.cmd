@echo off
rem Packs the app into a Content Manager ready zip. No arguments, no dependencies.
rem The work is done in pack.ps1 (PowerShell 5.1 ships with Windows).
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0pack.ps1"
if not "%errorlevel%"=="0" (
    echo.
    echo pack failed, see the message above.
    pause
)
exit /b %errorlevel%
