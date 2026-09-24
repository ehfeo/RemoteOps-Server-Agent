<#
  stop-agent.ps1 - stop the running RemoteOps agent on this machine.

  Usage (Administrator PowerShell, from the remote-agent folder):
      powershell -ExecutionPolicy Bypass -File stop-agent.ps1

  It kills only processes whose command line points at agent.ps1, so it
  will never touch other PowerShell windows.
#>

param(
    [string] $Dir = ''
)

$ErrorActionPreference = 'Continue'
if ($Dir -eq '') { $Dir = Split-Path -Parent $MyInvocation.MyCommand.Path }

function AgentProcs {
    $me = $PID
    return @(Get-WmiObject Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -ne $me -and $_.CommandLine -and ($_.CommandLine -match '[\\/]agent\.ps1') })
}

$procs = AgentProcs

if ($procs.Count -eq 0) {
    Write-Host 'No running agent process found.' -ForegroundColor Yellow
} else {
    foreach ($pr in $procs) {
        Write-Host ('Stopping pid=' + $pr.ProcessId)
        try { Stop-Process -Id $pr.ProcessId -Force -ErrorAction SilentlyContinue } catch { }
    }
    Start-Sleep -Seconds 2
}

$still = @(Get-WmiObject Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and ($_.CommandLine -match '[\\/]agent\.ps1') })

if ($still.Count -eq 0) {
    Write-Host 'Agent stopped.' -ForegroundColor Green
} else {
    Write-Host ('Still running: ' + (($still | ForEach-Object { $_.ProcessId }) -join ', ')) -ForegroundColor Red
}

Write-Host ''
Write-Host 'Note: the http URL reservation (netsh urlacl) is left in place,'
Write-Host 'so start-agent.bat can be used again on the same port.'
