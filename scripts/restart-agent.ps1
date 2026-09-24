<#
  restart-agent.ps1 - swap the running agent for a fresh one using a
  passphrase supplied on the command line.

  Designed to be launched detached by the OLD agent: it waits a few seconds
  so the caller can finish answering its HTTP request, kills the old agent,
  starts a new one, and records everything to restart.log.

  Safe: if the new agent does not answer within 30s, the old files are still
  on disk (.bak copies exist) and the operator can just run start-agent.bat.
#>

param(
    [int]    $Port      = 8370,
    [string] $Password  = '',
    [string] $Dir       = ''
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

if ($Dir -eq '') { $Dir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$log = Join-Path $Dir 'restart.log'

function W([string] $s) {
    $line = (Get-Date).ToString('HH:mm:ss') + '  ' + $s
    Add-Content -Path $log -Value $line -Encoding ASCII
}

W 'restart-agent.ps1 starting'
W ('  port=' + $Port + '  dir=' + $Dir)
if ($Password -eq '') {
    W '  ERROR: no password supplied, refusing to start unauthenticated'
    exit 1
}
W ('  password length=' + $Password.Length)

# give the caller time to finish its HTTP response
Start-Sleep -Seconds 4

W 'killing old agent ...'
$me = $PID
$procs = @(Get-WmiObject Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessId -ne $me -and $_.CommandLine -and ($_.CommandLine -match '[\\/]agent\.ps1') })
foreach ($pr in $procs) {
    W ('  kill pid=' + $pr.ProcessId)
    try { Stop-Process -Id $pr.ProcessId -Force -ErrorAction SilentlyContinue } catch { W ('    ' + $_.Exception.Message) }
}
Start-Sleep -Seconds 2

W 'launching new agent ...'
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$argList = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass',
             '-File', (Join-Path $Dir 'start-agent.ps1'),
             '-Port', $Port, '-Password', $Password)
try {
    $p = Start-Process -FilePath $psExe -ArgumentList $argList -WindowStyle Hidden -PassThru
    W ('  launched pid=' + $p.Id)
} catch {
    W ('  LAUNCH FAILED: ' + $_.Exception.Message)
    exit 2
}

W 'probing health ...'
$alive = $false
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 1
    try {
        $req = [System.Net.HttpWebRequest]::Create('http://127.0.0.1:' + $Port + '/health')
        $req.Headers['X-Agent-Token'] = $Password
        $req.Timeout = 3000
        $resp = $req.GetResponse()
        $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $body = $sr.ReadToEnd(); $sr.Close(); $resp.Close()
        W ('  ALIVE after ' + ($i + 1) + 's : ' + $body)
        $alive = $true
        break
    } catch { }
}
if (-not $alive) {
    W '  NEW AGENT DID NOT ANSWER within 30s'
    W '  -> run start-agent.bat manually on the server to recover'
    exit 3
}
W 'restart completed OK'
