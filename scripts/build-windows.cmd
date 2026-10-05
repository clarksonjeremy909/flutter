@echo off
REM Double-click or: scripts\build-windows.cmd
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-windows.ps1"
exit /b %ERRORLEVEL%
