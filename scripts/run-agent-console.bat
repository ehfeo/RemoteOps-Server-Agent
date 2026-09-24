@echo off
rem Interactive / foreground run - useful for a first smoke test.
rem Ctrl+C stops the agent.
setlocal
set "DIR=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%DIR%agent.ps1" %*
pause
