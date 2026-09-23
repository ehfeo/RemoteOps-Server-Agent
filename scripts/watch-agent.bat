@echo off
rem ============================================================
rem  RemoteOps Agent - 活动日志
rem  实时显示 AI 在服务器上执行了什么命令、结果如何。
rem  关闭本窗口不会停止 agent。
rem ============================================================
title RemoteOps Agent - 活动日志
set "DIR=%~dp0"

if not exist "%DIR%watch-agent.ps1" (
    echo 找不到 watch-agent.ps1
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%DIR%watch-agent.ps1" -Dir "%DIR%."
pause
