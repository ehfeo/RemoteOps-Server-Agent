<#
  watch-agent.ps1 - live activity console.

  Tails agent.log in a visible window so the operator can see, in real time,
  what the AI is doing on this server: every request that arrives (>>) and
  what came of it (<<).

  It is a SEPARATE process from the agent on purpose. Closing this window
  must never stop the agent - people instinctively close console windows, and
  the agent used to die that way.

  Usage:  double-click watch-agent.bat
          powershell -ExecutionPolicy Bypass -File watch-agent.ps1 -Dir C:\path
#>

param(
    [string] $Dir  = '',
    [int]    $Tail = 25,
    [string] $Lang = 'zh'
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

if ($Dir -eq '') { $Dir = Split-Path -Parent $MyInvocation.MyCommand.Path }
if ($Dir.EndsWith('\') -and $Dir.Length -gt 3) { $Dir = $Dir.Substring(0, $Dir.Length - 1) }

$libUi = Join-Path $Dir 'lib-ui.ps1'
if (Test-Path $libUi -PathType Leaf) {
    try { . $libUi } catch { $script:UiStrings = @{} }
}
if (-not (Get-Command T -ErrorAction SilentlyContinue)) {
    function T { param([string]$Key = '', [string]$Fallback = '') return $Fallback }
}
if (-not (Get-Command Import-UiStrings -ErrorAction SilentlyContinue)) {
    function Import-UiStrings { param([string]$Dir = '', [string]$Lang = 'zh') $script:UiStrings = @{} }
}
Import-UiStrings -Dir $Dir -Lang $Lang

try { $Host.UI.RawUI.WindowTitle = (T 'watch.title' 'RemoteOps Agent - activity log') } catch { }

$log = Join-Path $Dir 'agent.log'

if (-not (Test-Path $log -PathType Leaf)) {
    Write-Host (T 'watch.waiting' 'Waiting for agent.log to appear ...') -ForegroundColor Yellow
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Seconds 1
        if (Test-Path $log -PathType Leaf) { break }
    }
}
if (-not (Test-Path $log -PathType Leaf)) {
    Write-Host ((T 'watch.missing' 'agent.log not found:') + ' ' + $log) -ForegroundColor Red
    Write-Host ''
    Start-Sleep -Seconds 20
    exit 1
}

Write-Host ((T 'watch.following' 'Following agent.log:') + ' ' + $log) -ForegroundColor Cyan
Write-Host ''

Get-Content -Path $log -Tail $Tail -Wait -Encoding UTF8 | ForEach-Object {
    $c = 'Gray'
    if ($_ -match 'DENY|ERROR|FATAL')           { $c = 'Red' }
    elseif ($_ -match '\|\s*>>')                { $c = 'Cyan' }
    elseif ($_ -match '\|\s*<<')                { $c = 'Green' }
    elseif ($_ -match 'START|STOPPED')          { $c = 'Yellow' }
    Write-Host $_ -ForegroundColor $c
}
