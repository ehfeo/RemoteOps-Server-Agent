@echo off
setlocal
set "DIR=%~dp0"
echo === RemoteOps Agent installer ===
echo Dir: %DIR%
echo.
rem  Do NOT add -NonInteractive here: Read-Host throws under it, so the
rem  password prompt could never appear. The .ps1 now degrades gracefully
rem  instead of crashing if it is ever run non-interactively anyway.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%DIR%install-agent.ps1" %*
echo.
pause
