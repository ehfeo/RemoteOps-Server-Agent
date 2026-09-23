@echo off
rem ============================================================
rem  RemoteOps Agent - launcher (ASCII only, GBK-safe)
rem  Start the agent and ask for a password interactively.
rem  Eg. start-agent.bat  ->  prompts for port / IP allow / password
rem      start-agent.bat 8370  ->  fixed port, still asks password
rem ============================================================
setlocal enabledelayedexpansion
title RemoteOps Agent
set "DIR=%~dp0"

echo ============================================================
echo   RemoteOps Agent
echo   Folder: %DIR%
echo ============================================================
echo.

rem ---- port ----
set "PORT=8765"
set "PARAM_PORT=%~1"
if not "%PARAM_PORT%"=="" set "PORT=%PARAM_PORT%"
set /p "PORT=Listen port [%PORT%]: "
if "!PORT!"=="" set "PORT=8765"

rem ---- optional source IP allow-list ----
echo.
echo   Optional: restrict to one source IP (blank = any).
set "ALLOW="
set /p "ALLOW=Allow source IP [blank = any]: "

echo.
echo   Password is prompted next (hidden). Keep it secret - it grants
echo   remote command execution as this user.
echo.
echo   Starting ...
echo.

if "!ALLOW!"=="" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%DIR%start-agent.ps1" -Port !PORT! -AskPassword
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%DIR%start-agent.ps1" -Port !PORT! -AskPassword -AllowFrom !ALLOW!
)

if errorlevel 1 (
    echo.
    echo   Agent failed to start.
    echo   Direct way:  powershell -ExecutionPolicy Bypass -File "%DIR%start-agent.ps1" -Port !PORT! -Password "your-password"
) else (
    echo.
    echo   Agent running. Leave this window open.
    echo   IMPORTANT: only share the address with people you trust.
    echo   Open the matching TCP port in the cloud/firewall too.
    echo   To watch live logs: double-click watch-agent.bat
)
echo.
pause