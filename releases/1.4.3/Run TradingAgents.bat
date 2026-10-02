@echo off
rem Starts the TradingAgents window (ta-app.ps1). Falls back to the old black-window run if the window file is missing.
setlocal
if not exist "%~dp0ta-app.ps1" goto console
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "%~dp0ta-app.ps1"
exit /b 0

:console
call "%~dp0Run TradingAgents (console).bat"
exit /b %ERRORLEVEL%
