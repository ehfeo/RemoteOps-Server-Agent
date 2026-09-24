@echo off
title RemoteOps Agent - stop
setlocal
set "DIR=%~dp0"

echo ============================================================
echo   RemoteOps Agent - stop
echo   Dir: %DIR%
echo ============================================================
echo.

powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%DIR%stop-agent.ps1"

echo.
pause
