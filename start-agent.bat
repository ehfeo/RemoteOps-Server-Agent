@echo off
rem ============================================================
rem  RemoteOps Agent - 启动器
rem  请「以管理员身份运行」。不使用计划任务，直接启动。
rem
rem  注意：下面的 powershell 调用绝对不要加 -NonInteractive。
rem  一旦加了，Read-Host 会立刻抛异常，密码框永远出不来。
rem  （2026-09-23 踩过这个坑，agent 因此起不来）
rem ============================================================
setlocal enabledelayedexpansion
title RemoteOps Agent - 启动器
set "DIR=%~dp0"

echo ============================================================
echo   RemoteOps Agent - 启动器
echo   目录: %DIR%
echo ============================================================
echo.

rem ---- 端口 ----
set "PORT=8765"
set /p "PORT=监听端口 [8765]: "
if "!PORT!"=="" set "PORT=8765"

rem ---- 来源 IP 限制（可选）----
echo.
echo   可选：只允许某一个来源 IP 连接（不支持网段写法）。
echo   直接回车 = 不限制，任何知道密码的机器都能连。
echo.
set "ALLOW="
set /p "ALLOW=仅允许来自 IP [留空 = 不限制]: "

echo.
echo   接下来设置连接密码：输入时不可见，并且要输入两次，
echo   防止打错把自己锁在外面。
echo.
echo   正在启动 ...
echo.

if "!ALLOW!"=="" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%DIR%start-agent.ps1" -Port !PORT! -AskPassword
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%DIR%start-agent.ps1" -Port !PORT! -AskPassword -AllowFrom !ALLOW!
)

if errorlevel 1 (
    echo.
    echo ============================================================
    echo   agent 没有启动成功。
    echo   兜底办法 - 把密码直接写在命令行上启动：
    echo.
    echo   powershell -ExecutionPolicy Bypass -File "%DIR%start-agent.ps1" -Port !PORT! -Password "your-password"
    echo ============================================================
) else (
    rem Success: the copy-paste handoff block is printed last by start-agent.ps1.
)
echo.
pause
