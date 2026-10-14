@echo off
rem Installs the app into Assetto Corsa.
rem   install.cmd                        asks for the game folder and keeps the window open
rem   install.cmd "<path to AC>"         silent, sets the exit code
rem   install.cmd "<path to AC>" -Backup copies the current app folder into backups\ first
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
exit /b %errorlevel%
