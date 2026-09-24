@echo off
setlocal
set "DIR=%~dp0"
echo === RemoteOps Agent uninstaller ===
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%DIR%install-agent.ps1" -Uninstall %*
echo.
pause
