<#
  server-agent.ps1  -  minimal HTTP command agent for Windows Server 2012 R2
  Zero dependency: PowerShell 3.0+ and .NET HttpListener only.

  Endpoints
    GET  /howto                        -> SELF-DESCRIPTION, no password needed.
                                          Also served at / and /help.
                                          ?format=json|md   ?lang=zh (md only)
    GET  /health                       -> agent status
    GET  /info                         -> system / environment summary
    POST /exec                         -> {"cmd":"...","shell":"cmd|powershell","timeout":120,"cwd":""}
    POST /script                       -> raw body = powershell (or cmd) source, ?shell= & ?timeout=
    GET  /file?path=C:\x\y             -> download raw bytes
    POST /file                         -> {"path":"...","encoding":"base64|utf8","content":"..."}
    GET  /tail?path=...&lines=200      -> last N lines of a text file
    GET  /ls?path=...                  -> directory listing
    GET  /process[?name=...]           -> list processes (v1.3)
    POST /process                      -> {"action":"kill","pid":123|"name":"x.exe"}
    GET  /service[?name=...]           -> list services (v1.3)
    POST /service                      -> {"action":"start|stop|restart","name":"..."}
    GET  /zip?path=...                 -> download a file OR a whole directory as .zip
    POST /unzip                        -> {"path":"C:\\dest","encoding":"base64|utf8","content":"<zip>"}
    GET  /audit?lines=100              -> recent activity log entries (audit trail)
    POST /stop                         -> shut the agent down

  Auth: header X-Agent-Token  (if -Token set)  +  optional -AllowFrom IP list
  TLS:  pass -CertThumbprint <thumb> to serve HTTPS instead of HTTP (the URL
        must be reserved first: netsh http add sslcert ipport=0.0.0.0:PORT certhash=<thumb>).
#>

param(
    [int]      $Port           = 8765,
    [string]   $BindAddress    = '+',
    [string]   $Token          = '',
    [string[]] $AllowFrom      = @(),
    [string]   $WorkDir        = '',
    [int]      $DefaultTimeout = 120,
    [int]      $MaxTimeout     = 900,
    [string]   $CertThumbprint = '',
    [switch]   $NoLog,
    # Internal. When set, this process acts as a per-request worker (a runspace
    # spawned by the listener thread). It loads all functions/state, then returns
    # WITHOUT starting its own listener. Used by the concurrent-accept loop below.
    [switch]   $ThreadWorker
)

$ErrorActionPreference = 'Stop'
$AgentVersion = '2.1'

# ---------------------------------------------------------------- setup

if ([string]::IsNullOrWhiteSpace($WorkDir)) {
    $WorkDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    if ([string]::IsNullOrWhiteSpace($WorkDir)) { $WorkDir = (Get-Location).Path }
}

$LogFile = Join-Path $WorkDir 'agent.log'
$JobDir  = Join-Path $WorkDir 'jobs'
if (-not (Test-Path $JobDir)) { New-Item -ItemType Directory -Path $JobDir -Force | Out-Null }

if ($Token -eq '' -and (Test-Path (Join-Path $WorkDir 'token.txt'))) {
    try { $Token = (Get-Content (Join-Path $WorkDir 'token.txt') -Raw).Trim() } catch { $Token = '' }
}

# Persist the boot parameters so a self-reload (/reload) can relaunch this agent
# with the exact same arguments. Token is intentionally kept out (it is read from
# token.txt, or passed on the command line) so no secret is written to disk.
$script:Boot = @{
    script   = (Join-Path $WorkDir 'agent.ps1')
    workDir  = $WorkDir
    port     = $Port
    bind     = $BindAddress
    allow    = @($AllowFrom)
    cert     = $CertThumbprint
    noLog    = [bool]$NoLog.IsPresent
}
$bootJson = @{ path=(Join-Path $WorkDir 'agent.boot.json'); encoding='utf8'; content=($script:Boot | ConvertTo-Json -Compress) }
try { [System.IO.File]::WriteAllText((Join-Path $WorkDir 'agent.boot.json'), ($script:Boot | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding($false))) } catch { }

# ---------------------------------------------------------------- activity log
#
# Every request writes two lines: ">>" when it arrives and "<<" when it is
# finished, so watch-agent.ps1 (and the human watching it) can see what the
# agent is doing right now, not only what it already did.

$script:LogMaxBytes = 4 * 1024 * 1024
$script:LogCounter  = 0

function Write-Log {
    param([string]$Message)
    if ($NoLog) { return }
    $line = '{0} | {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 } catch { }
    $script:LogCounter++
    if ($script:LogCounter -ge 25) { $script:LogCounter = 0; Reset-LogIfHuge }
}

# agent.log would otherwise grow forever. Keep the tail, drop the head.
function Reset-LogIfHuge {
    try {
        if (-not (Test-Path $LogFile -PathType Leaf)) { return }
        if ((Get-Item $LogFile).Length -lt $script:LogMaxBytes) { return }
        $keep = @(Get-Content -Path $LogFile -Tail 400 -ErrorAction SilentlyContinue)
        $utf8Bom = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::WriteAllLines($LogFile, (@('--- log rotated, older entries dropped ---') + $keep), $utf8Bom)
    } catch { }
}

# One-line preview of a command or of its output, for the activity log.
function Shorten {
    param([string]$Text, [int]$Max = 300)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $s = $Text -replace "`r", ' '
    $s = $s -replace "`n", ' '
    $s = ($s -replace '\s+', ' ').Trim()
    if ($s.Length -gt $Max) { $s = $s.Substring(0, $Max) + ' ...(+' + ($Text.Length - $Max) + ' chars)' }
    return $s
}

function Write-Result {
    param([string]$Tag, $Result)
    $tail = ''
    if ($Result.timedOut) { $tail = ' TIMEOUT' }
    Write-Log ('<< ' + $Tag + ' exit=' + $Result.exitCode + ' ' + $Result.durationMs + 'ms' +
               ' out=' + ([string]$Result.stdout).Length + 'B' +
               ' err=' + ([string]$Result.stderr).Length + 'B' + $tail)
    if (([string]$Result.stdout).Trim() -ne '') { Write-Log ('   stdout | ' + (Shorten ([string]$Result.stdout) 300)) }
    if (([string]$Result.stderr).Trim() -ne '') { Write-Log ('   stderr | ' + (Shorten ([string]$Result.stderr) 300)) }
}

# ---------------------------------------------------------------- helpers

function Read-Body {
    param($Context)
    $sr = New-Object System.IO.StreamReader($Context.Request.InputStream, [System.Text.Encoding]::UTF8)
    $s  = $sr.ReadToEnd()
    $sr.Close()
    return $s
}

function Send-Json {
    param($Context, [int]$Code, $Object)
    $json  = $Object | ConvertTo-Json -Depth 8 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $Context.Response.StatusCode  = $Code
    $Context.Response.ContentType = 'application/json; charset=utf-8'
    $Context.Response.AddHeader('Cache-Control','no-store')
    try { $Context.Response.ContentLength64 = $bytes.Length } catch { }
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.OutputStream.Close()
}

function Send-Bytes {
    param($Context, [int]$Code, [byte[]]$Bytes, [string]$ContentType = 'application/octet-stream')
    $Context.Response.StatusCode  = $Code
    $Context.Response.ContentType = $ContentType
    try { $Context.Response.ContentLength64 = $Bytes.Length } catch { }
    $Context.Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
    $Context.Response.OutputStream.Close()
}

function Send-Text {
    param($Context, [int]$Code, [string]$Text, [string]$ContentType = 'text/plain; charset=utf-8')
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $Context.Response.StatusCode  = $Code
    $Context.Response.ContentType = $ContentType
    $Context.Response.AddHeader('Cache-Control','no-store')
    try { $Context.Response.ContentLength64 = $bytes.Length } catch { }
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.OutputStream.Close()
}

# Structured error response: {ok:false, code, message, detail?}.
# "error" is kept alongside for backward compatibility with 1.x clients.
function Send-Error {
    param($Context, [int]$Code = 500, [string]$ErrorCode = 'error',
          [string]$Message = '', [string]$Detail = '')
    Write-Log ("ERROR $ErrorCode : $Message")
    Send-Json $Context $Code @{ ok=$false; code=$ErrorCode; error=$Message; message=$Message; detail=$Detail }
}

# Send a pre-serialized JSON string (avoids ConvertTo-Json infinite loops / deadlocks
# on certain string arrays in Windows PowerShell 5.1; also lets callers keep full control).
function Send-JsonRaw {
    param($Context, [int]$Code, [string]$Json)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Json)
    $Context.Response.StatusCode  = $Code
    $Context.Response.ContentType = 'application/json; charset=utf-8'
    $Context.Response.AddHeader('Cache-Control','no-store')
    try { $Context.Response.ContentLength64 = $bytes.Length } catch { }
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.OutputStream.Close()
}

# JSON-escape one string value so it can be embedded in manually built JSON.
function ConvertTo-JsonString {
    param([string]$Value)
    if ($null -eq $Value) { return '""' }
    $s = $Value -replace '\\', '\\\\' -replace '"', '\"'
    $s = $s -replace "`r", '\r' -replace "`n", '\n' -replace "`t", '\t'
    $s = [regex]::Replace($s, '[\u0000-\u001F]', { param($m) ('\u{0:x4}' -f [int][char]$m.Value) })
    return '"' + $s + '"'
}

function Test-IpAllowed {
    param($Context)
    if ($script:AllowFrom.Count -gt 0) {
        $ip = ''
        try { $ip = $Context.Request.RemoteEndPoint.Address.ToString() } catch { }
        if ($script:AllowFrom -notcontains $ip) { return $false }
    }
    return $true
}

function Test-RequestAuth {
    param($Context)
    if (-not (Test-IpAllowed $Context)) { return $false }
    if ($script:Token -ne '') {
        $got = $Context.Request.Headers['X-Agent-Token']
        if ($got -ne $script:Token) { return $false }
    }
    return $true
}

# ---------------------------------------------------------------- fail2ban
#
# Brute-force protection, tracked per source IP. After $script:FailMax failed
# auths inside $script:FailWindow seconds, the IP is locked out for
# $script:FailLockSec (several endpoints then return HTTP 429).
# Workers run in separate runspaces and cannot share memory, so the ban table
# lives in agent.fail.json (a small file beside the agent) guarded by a named
# mutex. That keeps it correct across all concurrent workers AND across /reload.

$script:FailFile    = Join-Path $WorkDir 'agent.fail.json'
$script:FailMutexNm = 'Local\pws-agent-fail-' + $WorkDir.GetHashCode().ToString('x8')
$script:FailMax     = 5      # failed attempts allowed
$script:FailWindow  = 300    # ... within this many seconds
$script:FailLockSec = 900    # lockout duration once exceeded (seconds)

function Get-FailState {
    $base = @{ maxAttempts=$script:FailMax; windowSec=$script:FailWindow; lockSec=$script:FailLockSec }
    if (Test-Path $script:FailFile) {
        try { $o = Get-Content $script:FailFile -Raw | ConvertFrom-Json } catch { $o = $null }
        if ($o) {
            if ($null -ne $o.maxAttempts) { $base.maxAttempts = [int]$o.maxAttempts }
            if ($null -ne $o.windowSec)   { $base.windowSec   = [int]$o.windowSec }
            if ($null -ne $o.lockSec)     { $base.lockSec     = [int]$o.lockSec }
            $base.fails = Convert-FailsToHashtable $o.fails
            return $base
        }
    }
    $base.fails = @{}
    return $base
}

function Save-FailState {
    param($State)
    try {
        [System.IO.File]::WriteAllText($script:FailFile, ($State | ConvertTo-Json -Compress -Depth 8),
                                       (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

# Rebuild the fails map as a hashtable. In-memory it is a Hashtable (use .Keys);
# read back from JSON it is a PSCustomObject (use .PSObject.Properties). Never use
# .PSObject.Properties on a Hashtable - it yields structural props (Count, Keys, ...).
function Convert-FailsToHashtable {
    param($Fails)
    $h = @{}
    if ($null -eq $Fails) { return $h }
    if ($Fails -is [System.Collections.Hashtable]) {
        foreach ($k in $Fails.Keys) {
            $v = $Fails[$k]
            if ($v -is [System.Management.Automation.PSCustomObject]) {
                $h[$k] = @{ count=[int]$v.count; first=[int]$v.first; banUntil=[int]$v.banUntil }
            } else { $h[$k] = $v }
        }
    } else {
        foreach ($k in @($Fails.PSObject.Properties)) {
            $v = $k.Value
            if ($v -is [System.Management.Automation.PSCustomObject]) {
                $h[$k.Name] = @{ count=[int]$v.count; first=[int]$v.first; banUntil=[int]$v.banUntil }
            } else { $h[$k.Name] = $v }
        }
    }
    return $h
}

function Update-FailState {
    # Serialize read-modify-write across concurrent worker runspaces.
    param([string]$Ip, [ValidateSet('fail','ok')]$Action)
    if (-not $Ip) { return }
    $m = $null
    try { $m = New-Object System.Threading.Mutex($false, $script:FailMutexNm) } catch { }
    try { if ($m) { [void] $m.WaitOne(3000) } } catch { }
    $dirty = $false
    try {
        $s   = Get-FailState
        $now = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $fails = Convert-FailsToHashtable $s.fails
        $dirty = $true
        if ($Action -eq 'ok') {
            # only write when the IP actually had recorded failures
            if ($fails.ContainsKey($Ip)) { $fails.Remove($Ip) } else { $dirty = $false }
        } else {
            $e = $null
            if ($fails.ContainsKey($Ip)) { $e = $fails[$Ip] }
            if ($null -eq $e) { $e = @{ count=0; first=$now; banUntil=0 } }
            if ([int]$e.count -eq 0 -or ($now - [int]$e.first) -gt $script:FailWindow) { $e.first = $now; $e.count = 0 }
            $e.count = [int]$e.count + 1
            if ([int]$e.count -ge $script:FailMax) { $e.banUntil = $now + $script:FailLockSec }
            $fails[$Ip] = $e
        }
        # prune entries that are neither in lockout nor counted within the window
        $pruned = @{}
        foreach ($k in @($fails.Keys)) {
            $v = $fails[$k]
            if ([int]$v.banUntil -gt $now) { $pruned[$k] = $v; continue }
            if (($now - [int]$v.first) -le $script:FailWindow -and [int]$v.count -gt 0) { $pruned[$k] = $v; continue }
        }
        $s.fails = $pruned
        if ($dirty) { Save-FailState $s }
    } catch { }
    finally { try { if ($m) { $m.ReleaseMutex(); $m.Dispose() } } catch { } }
}

function Get-BanUntil {
    param([string]$Ip)
    if (-not $Ip) { return 0 }
    $s = Get-FailState
    if ($s.fails -and $s.fails.ContainsKey($Ip)) {
        $e   = $s.fails[$Ip]
        $now = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        if ([int]$e.banUntil -gt $now) { return [int]$e.banUntil }
    }
    return 0
}

function Test-Banned {
    param([string]$Ip)
    return ((Get-BanUntil $Ip) -gt 0)
}

function Get-FailSummary {
    $s   = Get-FailState
    $now = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $list = @()
    if ($s.fails) {
        foreach ($k in $s.fails.Keys) {
            $v = $s.fails[$k]
            $list += @{ ip=$k; count=[int]$v.count; first=[int]$v.first; banUntil=[int]$v.banUntil }
        }
    }
    return @{ maxAttempts=[int]$s.maxAttempts; windowSec=[int]$s.windowSec; lockSec=[int]$s.lockSec;
              now=$now; failures=$list }
}

function Clear-FailAll {
    $m = $null
    try { $m = New-Object System.Threading.Mutex($false, $script:FailMutexNm) } catch { }
    try { if ($m) { [void] $m.WaitOne(3000) } } catch { }
    try { if (Test-Path $script:FailFile) { Remove-Item $script:FailFile -Force -ErrorAction SilentlyContinue } } catch { }
    finally { try { if ($m) { $m.ReleaseMutex(); $m.Dispose() } } catch { } }
}

function ConvertFrom-JsonSafe {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    try { return ($Text | ConvertFrom-Json) } catch { return $null }
}

# ---------------------------------------------------------------- execution

function Invoke-ShellText {
    param(
        [string]$CommandText,
        [string]$Shell      = 'cmd',
        [int]   $TimeoutSec = 120,
        [string]$Cwd        = ''
    )

    if ($TimeoutSec -lt 1)      { $TimeoutSec = 1 }
    if ($TimeoutSec -gt $script:MaxTimeout) { $TimeoutSec = $script:MaxTimeout }

    $id   = [guid]::NewGuid().ToString('N')
    $dir  = Join-Path $JobDir $id
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.RedirectStandardInput  = $true
    $psi.CreateNoWindow         = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8
    if ($Cwd -and (Test-Path $Cwd)) { $psi.WorkingDirectory = $Cwd }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    # PowerShell 2.0-5.1 parses a BOM-less .ps1 as ANSI(GBK), which mangles any
    # non-ASCII literal. Always emit the script wrapper WITH a UTF-8 BOM.
    $utf8Bom   = New-Object System.Text.UTF8Encoding($true)

    if ($Shell -eq 'powershell') {
        # Write the user script verbatim (so a leading param() block stays legal),
        # then invoke it through -EncodedCommand with a prelude that forces UTF-8
        # console output. Base64 avoids every quoting pitfall.
        $file = Join-Path $dir 'run.ps1'
        [System.IO.File]::WriteAllText($file, $CommandText, $utf8Bom)
        $prelude =
            "[Console]::OutputEncoding=[System.Text.Encoding]::UTF8`n" +
            "[Console]::InputEncoding=[System.Text.Encoding]::UTF8`n" +
            "`$ErrorActionPreference='Continue'`n" +
            "`$ProgressPreference='SilentlyContinue'`n" +
            "& '" + $file + "'`n"
        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($prelude))
        $psi.FileName  = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $psi.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + $encoded
    } else {
        $file = Join-Path $dir 'run.bat'
        $pre  = "@echo off`r`nchcp 65001 >nul`r`n"
        [System.IO.File]::WriteAllText($file, $pre + $CommandText, $utf8NoBom)
        $psi.FileName  = Join-Path $env:SystemRoot 'System32\cmd.exe'
        $psi.Arguments = '/c "' + $file + '"'
    }

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi

    $timedOut = $false
    try { $p.Start() | Out-Null } catch {
        Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
        return @{ ok=$false; error='start failed: ' + $_.Exception.Message; exitCode=-1; stdout=''; stderr=''; timedOut=$false; durationMs=0 }
    }
    try { $p.StandardInput.Close() } catch { }

    $outTask = $null; $errTask = $null
    try {
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()
    } catch { $outTask = $null; $errTask = $null }

    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        $timedOut = $true
        try { $p.Kill() } catch { }
        try {
            $tk = Join-Path $env:SystemRoot 'System32\taskkill.exe'
            & $tk /F /T /PID $p.Id 2>&1 | Out-Null
        } catch { }
        $p.WaitForExit(5000) | Out-Null
    }

    $outText = ''; $errText = ''
    if ($outTask -ne $null) {
        try { $null = $outTask.Wait(15000); $outText = $outTask.Result } catch { }
        try { $null = $errTask.Wait(15000); $errText = $errTask.Result } catch { }
    } else {
        try { $outText = $p.StandardOutput.ReadToEnd() } catch { }
        try { $errText = $p.StandardError.ReadToEnd()  } catch { }
    }

    $exitCode = -1
    try { $exitCode = $p.ExitCode } catch { }
    $sw.Stop()

    Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue

    return @{
        ok         = $true
        exitCode   = $exitCode
        stdout     = [string]$outText
        stderr     = [string]$errText
        timedOut   = $timedOut
        durationMs = [int]$sw.Elapsed.TotalMilliseconds
        shell      = $Shell
    }
}

# ---------------------------------------------------------------- info

function Get-SystemInfo {
    $os = Get-WmiObject Win32_OperatingSystem -ErrorAction SilentlyContinue
    $cs = Get-WmiObject Win32_ComputerSystem  -ErrorAction SilentlyContinue
    $isAdmin = $false
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $isAdmin = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
                     [Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { }

    $drives = @()
    foreach ($d in (Get-WmiObject Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue)) {
        $drives += (@{ drive=$d.DeviceID; freeGB=[math]::Round($d.FreeSpace/1GB,2); sizeGB=[math]::Round($d.Size/1GB,2) })
    }

    $mysqlSvc = @()
    Get-Service -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'mysql' -or $_.DisplayName -match 'mysql' } |
        ForEach-Object { $mysqlSvc += (@{ name=$_.Name; display=$_.DisplayName; status=$_.Status.ToString() }) }

    return @{
        hostname    = $env:COMPUTERNAME
        user        = ($env:USERDOMAIN + '\' + $env:USERNAME)
        isAdmin     = $isAdmin
        osCaption   = if ($os) { $os.Caption } else { '' }
        osVersion   = if ($os) { $os.Version } else { '' }
        osArch      = if ($cs) { $cs.SystemType } else { $env:PROCESSOR_ARCHITECTURE }
        psVersion   = $PSVersionTable.PSVersion.ToString()
        clrVersion  = $PSVersionTable.CLRVersion.ToString()
        systemRoot  = $env:SystemRoot
        drives      = $drives
        mysqlServices = $mysqlSvc
        agentVersion  = $AgentVersion
        timeUtc     = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
}

# ---------------------------------------------------------------- self description
#
# /howto is intentionally UNAUTHENTICATED. A brand new AI assistant that has only
# been told "host + port" must be able to learn the protocol before it owns any
# secret. It leaks no secret and exposes no command execution.

function Get-HowToEndpoints {
    return @(
        @{ method='GET';  path='/howto';   auth='none';
           purpose='This manual. Also reachable at / and /help.';
           params='?format=json|md (default json), ?lang=zh (md only, needs HOWTO.zh.md beside agent.ps1)';
           returns='JSON or Markdown description of the whole API' }
        @{ method='GET';  path='/health';  auth='password';
           purpose='Liveness probe and the fastest way to test a password.';
           params='none';
           returns='{"ok":true,"version":"1.2","hostname":"...","time":"...","peer":"..."}' }
        @{ method='GET';  path='/fail';    auth='password';
           purpose='fail2ban state: who is counted/locked out for brute force.';
           params='none (GET)';
           returns='{"maxAttempts":5,"windowSec":300,"lockSec":900,"now":...,"failures":[...]}' }
        @{ method='POST'; path='/fail';    auth='password';
           purpose='Admin the ban table. {"action":"clear"} resets all; {"action":"unban","ip":"x.x.x.x"} clears one IP.';
           params='JSON body';
           returns='Updated fail2ban state' }
        @{ method='GET';  path='/info';    auth='password';
           purpose='Environment summary: OS, PS version, admin flag, disks, MySQL services.';
           params='none';
           returns='object with hostname, user, isAdmin, osCaption, psVersion, drives, ...' }
        @{ method='POST'; path='/exec';    auth='password';
           purpose='Run one command. This is the workhorse.';
           params='JSON body: {"cmd":"...","shell":"cmd|powershell","timeout":120,"cwd":"C:\\..."}. shell defaults to cmd, timeout to 120, hard max 900.';
           returns='{"ok":true,"exitCode":0,"stdout":"...","stderr":"...","timedOut":false,"durationMs":123,"shell":"cmd"}' }
        @{ method='POST'; path='/script';  auth='password';
           purpose='Run a multi-line script. Raw request body IS the script source.';
           params='query: ?shell=powershell|cmd (default powershell), ?timeout=300';
           returns='same shape as /exec' }
        @{ method='GET';  path='/ls';      auth='password';
           purpose='List a directory.';
           params='?path=C:\\some\\dir';
           returns='{"ok":true,"path":"...","items":[{"name":..,"dir":..,"size":..,"mtime":..}]}' }
        @{ method='GET';  path='/tail';    auth='password';
           purpose='Read the last N lines of a text file (log files).';
           params='?path=C:\\x\\y.log&lines=200';
           returns='{"ok":true,"path":"...","totalLines":1234,"content":"..."}' }
        @{ method='GET';  path='/file';    auth='password';
           purpose='Download a file (raw bytes).';
           params='?path=C:\\x\\y.txt';
           returns='raw bytes, application/octet-stream' }
        @{ method='POST'; path='/file';    auth='password';
           purpose='Upload a file.';
           params='JSON body: {"path":"C:\\x\\y.txt","encoding":"base64|utf8","content":"..."}';
           returns='{"ok":true,"path":"...","bytes":123}' }
        @{ method='POST'; path='/stop';    auth='password';
           purpose='Shut the agent down. It will not restart by itself.';
           params='none';
           returns='{"ok":true,"stopping":true}' }
        @{ method='GET';  path='/process'; auth='password';
           purpose='List processes. Optional ?name= filter.';
           params='?name=notepad';
           returns='{"ok":true,"count":N,"items":[{name,pid,memMB,cpuSec,path,started}]}' }
        @{ method='POST'; path='/process'; auth='password';
           purpose='Kill a process by pid or by name.';
           params='JSON body: {"action":"kill","pid":123} or {"action":"kill","name":"x.exe"}';
           returns='{"ok":true,"killed":[pid,...]}' }
        @{ method='GET';  path='/service'; auth='password';
           purpose='List services. Optional ?name= filter.';
           params='?name=mysql';
           returns='{"ok":true,"count":N,"items":[{name,display,status,startType}]}' }
        @{ method='POST'; path='/service'; auth='password';
           purpose='Start/Stop/Restart a service.';
           params='JSON body: {"action":"start|stop|restart","name":"..."}';
           returns='{"ok":true,"name":..,"action":..,"status":..}' }
        @{ method='GET';  path='/zip';     auth='password';
           purpose='Download a file OR a whole directory as a .zip archive.';
           params='?path=C:\\some\\dir';
           returns='application/zip bytes' }
        @{ method='POST'; path='/unzip';   auth='password';
           purpose='Upload a base64 (or utf8) .zip and extract it into a directory.';
           params='JSON body: {"path":"C:\\dest","encoding":"base64|utf8","content":"<zip>"}';
           returns='{"ok":true,"path":..,"files":N}' }
        @{ method='GET';  path='/audit';   auth='password';
           purpose='Return recent entries from the activity log (audit trail).';
           params='?lines=100';
           returns='{"ok":true,"log":..,"count":N,"entries":[...]}' }
        @{ method='POST'; path='/reload';  auth='password';
           purpose='Self-reload: relaunch the agent from the CURRENT agent.ps1 on disk with the SAME boot args. The live "boost" mechanism - edit the script, POST /reload.';
           params='no body. The connection will drop; reconnect after a few seconds.';
           returns='{"ok":true,"reloading":true}' }
    )
}

function Get-HowToSelfExtend {
    return @(
      ,'This agent intentionally ships WITHOUT guessing which features you will need next.'
      ,'Instead it supports DIRECT, LIVE SELF-EXTENSION, so you add capability right when you need it.'
      ,'The pattern: (1) think of a feature, (2) add it to this script, (3) POST /reload to pick it up.'
      ,'HOW TO ADD A NEW ENDPOINT: open the "routing" switch in Handle-Request, add a case for your path that does the work and calls Send-Json/Send-Bytes/Send-Text. Optionally register it in Get-HowToEndpoints so /howto documents it automatically.'
      ,'HOW TO UPDATE THE SCRIPT: download agent.ps1 (GET /file), edit locally, then upload it back (POST /file, base64), then POST /reload to run the new code with the same port/workdir/token.'
      ,'This is the intended way to grow the agent: feature -> edit agent.ps1 -> POST /file -> POST /reload. No redeploy, no config change, no downtime beyond ~2 seconds.'
      ,'Tip: keep agent.ps1 small and survivable - one bug you ship via /reload can take the agent down, so test the edited script locally before applying it here.'
    )
}

function Get-HowToRules {
    return @(
      ,'Send the password on EVERY request except /howto, as HTTP header X-Agent-Token.'
      ,'Wrong or missing password returns HTTP 403 with {"ok":false,"error":"forbidden"}. It is not a network error.'
      ,'A /exec command is written to a temporary .bat and run with "cmd /c". Therefore batch syntax applies: a for loop variable must be written %%i, not %i.'
      ,'The default shell for /exec is cmd. Pass {"shell":"powershell"} to run PowerShell instead.'
      ,'When to STOP fighting quoting: if a powershell command contains & | < > @ $, single or double quotes, backslashes, newlines, or a leading param() block, it will only cause painful escaping mistakes. Do NOT inline-interpolate it into your shell as a JSON string. Put the script text in a local file and POST it with "curl --data-binary @file.ps1 /script?shell=powershell". The agent runs bombs-free either way, but /script saves YOU the escaping/parsing round-trips.'
      ,'Same rule for /exec: write the JSON body to a file (e.g. bodies/cmd.json) and send it with "curl --data-binary @bodies/cmd.json". Never build the JSON inline in a shell that may eat & @ " yourself.'
      ,'Brute-force protection: after 5 wrong X-Agent-Token from one IP within 300s, that IP is locked for 900s and every protected endpoint returns HTTP 429 {"ok":false,"code":"throttled"}. /howto needs no password and is never counted. GET /fail shows the table; POST /fail {"action":"clear"} or {"action":"unban","ip":"x.x.x.x"} clears it.'
      ,'stdin is closed immediately. Never send interactive commands and never use Read-Host or pause.'
      ,'Default timeout is 120 seconds, hard maximum 900. Pass an explicit timeout for long jobs such as installs or database initialization.'
      ,'Exit code is passed through in exitCode, but some Windows tools are unreliable: verify the actual effect rather than trusting exitCode alone.'
      ,'Native tools can mishandle command lines containing spaces (for example mysqld --defaults-file="C:\\Program Files\\..."). Prefer space-free paths for such tools.'
      ,'All text is UTF-8. Chinese output is safe on the /script and /exec paths.'
      ,'This agent runs commands as the Windows account that started it, usually Administrator. It is a remote command execution port: stop it when the work is done.'
    )
}

function Get-HowToSteps {
    return @(
        ,'You were given a host and a port. Fetch http://HOST:PORT/howto with NO password. This endpoint is public on purpose.'
        ,'Read the auth.required field below. If it is true, every other endpoint needs a password.'
        ,'Ask the human operator for the connection password. Do NOT guess it and do NOT brute force it. There is no remote way to recover or reset it.'
        ,'Send that password as HTTP header X-Agent-Token on every subsequent request.'
        ,'Verify with GET /health. HTTP 200 means the password is correct. HTTP 403 means it is wrong or missing.'
        ,'Then use /info, /exec, /script, /ls, /tail and /file to do the actual work.'
        ,'When finished, remind the human to stop the agent (stop-agent.bat on the server) or POST /stop.'
    )
}

function Get-HowTo {
    $hasPwd = ($script:Token -ne '')
    return @{
        ok       = $true
        product  = 'RemoteOps Server Agent'
        version  = $AgentVersion
        oneLine  = 'A zero-dependency HTTP agent that lets an AI assistant run commands on this Windows server.'
        listenHint = 'Base URL is http://HOST:PORT - no path prefix.'
        whatItIs = 'A single PowerShell script using only .NET HttpListener. No installers, no runtime, no outbound connection. It listens on one TCP port and executes the commands you send it, as the Windows user that started it (usually Administrator).'
        requirements = 'Windows with PowerShell 3.0 or newer (built for Windows Server 2012 R2 / PowerShell 4.0). The port must be allowed by BOTH the cloud security group and the Windows firewall, and the URL must be reserved with netsh (start-agent.bat does this).'
        auth = @{
            required = $hasPwd
            header   = 'X-Agent-Token'
            scheme   = 'Put the connection password in the HTTP request header X-Agent-Token. There is no login step, no cookie and no bearer token exchange.'
            howToGetPassword = 'The password is chosen by the human who started the agent on the server (start-agent.bat asks for it). If you are an AI assistant, ASK THE USER for it. It is never transmitted by this endpoint.'
            changableRemotely = $false
            resetHint = 'If the password is lost, the human must restart the agent on the server with a new one. You cannot recover it over the network.'
            onFailure = 'HTTP 403 {"ok":false,"error":"forbidden"}'
        }
        howToUseMe = @{
            step1 = 'GET /howto (no password) to read this manual - you just did.'
            step2 = 'Ask the human for the password.'
            step3 = 'Send it as X-Agent-Token on every request.'
            step4 = 'GET /health to confirm, then start working.'
        }
        bootstrapSteps = (Get-HowToSteps)
        endpoints = (Get-HowToEndpoints)
        rules = (Get-HowToRules)
        minimalClient = @{
            curl = @(
                'curl -H "X-Agent-Token: PASSWORD" http://HOST:PORT/health'
                'curl -H "X-Agent-Token: PASSWORD" -H "Content-Type: application/json" -d "{\"cmd\":\"ipconfig\",\"shell\":\"cmd\",\"timeout\":60}" http://HOST:PORT/exec'
                'curl -H "X-Agent-Token: PASSWORD" --data-binary @script.ps1 "http://HOST:PORT/script?shell=powershell&timeout=300"'
            )
            python = @(
                'import json, urllib.request'
                'BASE="http://HOST:PORT"; PWD="PASSWORD"'
                'def call(path, body=None, timeout=120):'
                '    data = json.dumps(body).encode() if body is not None else None'
                '    req = urllib.request.Request(BASE+path, data=data, method="POST" if data else "GET")'
                '    req.add_header("X-Agent-Token", PWD)'
                '    if data: req.add_header("Content-Type", "application/json")'
                '    return json.load(urllib.request.urlopen(req, timeout=timeout))'
                'print(call("/health"))'
                'print(call("/exec", {"cmd":"hostname","shell":"cmd"}))'
            )
        }
        troubleshooting = @{
            connectionTimeout = 'The packet never arrived: cloud security group or Windows firewall is blocking the port. Nothing is listening is usually "refused", not "timeout".'
            connectionRefused = 'The port is reachable but no agent is listening: the agent was stopped or never started.'
            http403 = 'Password missing or wrong.'
            http404 = 'Unknown endpoint path.'
            http500 = 'The agent itself threw an exception; the message is in the JSON error field.'
        }
        selfExtend = @{
            principle = 'No feature guessing: this agent grows on demand, live.'
            flow = 'feature -> edit agent.ps1 -> POST /file (base64) -> POST /reload'
            howToAddEndpoint = 'Add a case to the routing switch in Handle-Request, call Send-Json/Send-Bytes/Send-Text. Register in Get-HowToEndpoints so /howto documents it.'
            howToUpgrade = 'GET /file agent.ps1, edit locally, POST /file back, then POST /reload. Same port/workdir/token, ~2s downtime.'
            caution = 'Test the edited script locally first: /reload can ship a fatal bug that takes the agent down.'
            steps = (Get-HowToSelfExtend)
        }
        links = @{
            json     = '/howto'
            markdown = '/howto?format=md'
            markdownChinese = '/howto?format=md&lang=zh'
            health   = '/health'
        }
        aiPrompt = @{
            title  = 'AI Assistant bootstrap prompt - copy everything inside the box into your AI, then give it HOST, PORT and the password.'
            prompt = @(
                'You are talking to a RemoteOps Server Agent on a Windows machine.'
                'It is a zero-dependency PowerShell HTTP agent (no installer). It runs the commands you send it, as the Windows account that started it (usually Administrator).'
                ''
                ('Agent version: v' + $AgentVersion + '. Base URL: http://HOST:PORT.')
                ''
                'To work with it:'
                '1. Put the connection password in the HTTP header X-Agent-Token on EVERY request except /howto.'
                '2. HOST, PORT and PASSWORD are given to you by the human. GET /health to confirm the password, then GET /howto?format=md for the full manual.'
                '3. Small one-liners: POST /exec with {"cmd":"...","shell":"cmd|powershell","timeout":120}.'
                "4. Anything containing & | < > @ $, quotes, backslashes, newlines, or a leading param() block: put the text in a file and POST it via /script (?shell=powershell) with --data-binary @file. Never inline-interpolate such commands - you will fight quoting."
                '5. Verify actual effects, not just exitCode: Windows tools sometimes exit 0 anyway.'
                '6. Wrong or missing password returns HTTP 403; after 5 failures the IP is locked and returns HTTP 429 for 900s.'
            ) -join "`n"
        }
    }
}

function Get-HowToMarkdown {
    $L = @()
    $L += '# RemoteOps Server Agent v' + $AgentVersion
    $L += ''
    $L += 'A zero-dependency HTTP agent that lets an AI assistant run commands on this Windows server.'
    $L += 'It is one PowerShell script using only .NET HttpListener - no installer, no runtime, no outbound connection.'
    $L += ''
    $L += '## 1. Connect'
    $L += ''
    $L += '- Base URL: `http://HOST:PORT` (no path prefix)'
    $L += '- This page needs **no password**. Everything else does.'
    $L += '- Password goes in the HTTP header `X-Agent-Token`, on every request.'
    $L += '- Wrong or missing password -> `HTTP 403 {"ok":false,"error":"forbidden"}`.'
    $L += ''
    $L += '## 2. What you (the AI) should do'
    $L += ''
    $n = 0
    foreach ($s in (Get-HowToSteps)) { $n++; $L += ($n.ToString() + '. ' + $s) }
    $L += ''
    $L += '## 3. Endpoints'
    $L += ''
    $L += '| Method | Path | Auth | Purpose |'
    $L += '|---|---|---|---|'
    foreach ($e in (Get-HowToEndpoints)) {
        $L += ('| ' + $e.method + ' | `' + $e.path + '` | ' + $e.auth + ' | ' + $e.purpose + ' |')
    }
    $L += ''
    foreach ($e in (Get-HowToEndpoints)) {
        $L += '### ' + $e.method + ' ' + $e.path
        $L += ''
        $L += '- Params: ' + $e.params
        $L += '- Returns: ' + $e.returns
        $L += ''
    }
    $L += '## 4. Rules and gotchas'
    $L += ''
    foreach ($r in (Get-HowToRules)) { $L += '- ' + $r }
    $L += ''
    $L += '## 5. Minimal client'
    $L += ''
    $L += '```bash'
    foreach ($c in (Get-HowTo).minimalClient.curl) { $L += $c }
    $L += '```'
    $L += ''
    $L += '```python'
    foreach ($c in (Get-HowTo).minimalClient.python) { $L += $c }
    $L += '```'
    $L += ''
    $L += '## 6. Troubleshooting'
    $L += ''
    $L += '- Timeout -> blocked by cloud security group or Windows firewall.'
    $L += '- Connection refused -> nothing listening, the agent is stopped.'
    $L += '- HTTP 403 -> password missing or wrong.'
    $L += '- HTTP 404 -> unknown endpoint.'
    $L += ''
    $L += '## 7. Self-extension (live boost)'
    $L += ''
    foreach ($s in (Get-HowToSelfExtend)) { $L += '- ' + $s }
    $L += ''
    $L += '---'
    $L += 'This agent executes commands as the Windows account that started it, usually Administrator.'
    $L += 'Stop it (stop-agent.bat) when the job is done.'
    $L += ''
    $L += '## 8. AI Assistant Prompt (copy everything in the box)'
    $L += ''
    $L += 'Paste the block below into your AI (or the start of a new AI thread), then tell it HOST, PORT and the password.'
    $L += ''
    $L += '```text'
    foreach ($ln in ((Get-HowTo).aiPrompt.prompt -split "`n")) { $L += $ln }
    $L += '```'
    return ($L -join "`n")
}

# ---------------------------------------------------------------- v1.3 helpers

function Get-ProcessList {
    param([string]$Filter = '')
    $rows = @()
    $pat = if ($Filter) { '*' + $Filter + '*' } else { '' }
    Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
        if ($pat -and ($_.ProcessName -notlike $pat)) { return }
        $mem = 0; try { $mem = [math]::Round($_.WorkingSet64 / 1MB, 1) } catch { }
        $pth = ''; try { $pth = $_.Path } catch { }
        $st  = ''; try { $st  = $_.StartTime.ToString('yyyy-MM-dd HH:mm:ss') } catch { }
        $cpu = 0;  try { $cpu = [math]::Round($_.CPU, 1) } catch { }
        $rows += (@{
            name   = $_.ProcessName
            pid    = $_.Id
            memMB  = $mem
            cpuSec = $cpu
            path   = $pth
            started= $st
        })
    }
    return @($rows | Sort-Object pid)
}

function Invoke-KillProcess {
    param([int]$ProcessId = 0, [string]$Name = '')
    if ($ProcessId -eq 0 -and [string]::IsNullOrWhiteSpace($Name)) {
        return @{ ok=$false; message='need pid or name' }
    }
    $targets = @()
    if ($ProcessId -ne 0) {
        $p = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
        if ($p) { $targets += $p }
    }
    if ($Name) { $targets += @(Get-Process -Name $Name -ErrorAction SilentlyContinue) }
    # Dedupe by process Id (NOT Select-Object -Unique, which collapses distinct
    # Process objects on some PowerShell versions).
    $seen = @{}; $uniq = @()
    foreach ($t in $targets) { if (-not $seen.ContainsKey($t.Id)) { $seen[$t.Id] = $true; $uniq += $t } }
    $targets = $uniq
    if ($targets.Count -eq 0) {
        return @{ ok=$false; message='no matching process' }
    }
    $killed = @()
    foreach ($p in $targets) {
        try { Stop-Process -Id $p.Id -Force -ErrorAction Stop; $killed += $p.Id } catch { }
    }
    return @{ ok=$true; requestedPid=$ProcessId; name=$Name; killed=$killed }
}

function Get-ServiceList {
    param([string]$Filter = '')
    $rows = @()
    $pat = if ($Filter) { '*' + $Filter + '*' } else { '' }
    Get-Service -ErrorAction SilentlyContinue | ForEach-Object {
        if ($pat -and ($_.Name -notlike $pat -and $_.DisplayName -notlike $pat)) { return }
        $rows += (@{ name=$_.Name; display=$_.DisplayName; status=$_.Status.ToString(); startType=$_.StartType.ToString() })
    }
    return @($rows | Sort-Object name)
}

function Invoke-ServiceControl {
    param([string]$Name = '', [string]$Action = '')
    if ([string]::IsNullOrWhiteSpace($Name)) { return @{ ok=$false; message='need service name' } }
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { return @{ ok=$false; message='service not found' } }
    $failed = ''
    try {
        switch ($Action.ToLowerInvariant()) {
            'start'   { if ($svc.Status -ne 'Running') { Start-Service -Name $Name -ErrorAction Stop } }
            'stop'    { if ($svc.Status -ne 'Stopped')  { Stop-Service  -Name $Name -ErrorAction Stop } }
            'restart' { Restart-Service -Name $Name -ErrorAction Stop }
            default   { return @{ ok=$false; message="unknown action: $Action" } }
        }
    } catch { $failed = $_.Exception.Message }
    $now = (Get-Service -Name $Name -ErrorAction SilentlyContinue).Status.ToString()
    return @{ ok=($failed -eq ''); name=$Name; action=$Action; status=$now; error=$failed }
}

# Zip a file or a whole directory into bytes. Uses .NET ZipFile (PS4/.NET4.5+).
function Get-ZipBytes {
    param([string]$Path)
    try { Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop } catch { }
    $zip = Join-Path $JobDir ([guid]::NewGuid().ToString('N') + '.zip')
    $isDir = (Test-Path $Path -PathType Container)
    try {
        if ($isDir) {
            [System.IO.Compression.ZipFile]::CreateFromDirectory($Path, $zip)
        } else {
            $parent = Split-Path -Parent $Path
            $name   = Split-Path -Leaf   $Path
            $fs = [System.IO.File]::Create($zip)
            $za = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
            $za.CreateEntryFromFile($Path, $name) | Out-Null
            $za.Dispose(); $fs.Dispose()
        }
        $bytes = [System.IO.File]::ReadAllBytes($zip)
        return @{ ok=$true; bytes=$bytes; isDir=$isDir }
    } catch {
        return @{ ok=$false; error=$_.Exception.Message }
    } finally {
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
    }
}

# Extract a zip (bytes) into a destination directory.
function Expand-ZipBytes {
    param([string]$Dest, [byte[]]$Bytes)
    if ([string]::IsNullOrWhiteSpace($Dest)) { return @{ ok=$false; message='need dest path' } }
    try { Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop } catch { }
    $tmp = Join-Path $JobDir ([guid]::NewGuid().ToString('N') + '.zip')
    try {
        [System.IO.File]::WriteAllBytes($tmp, $Bytes)
        if (-not (Test-Path $Dest)) { New-Item -ItemType Directory -Path $Dest -Force | Out-Null }
        [System.IO.Compression.ZipFile]::ExtractToDirectory($tmp, $Dest)
        $count = @(Get-ChildItem -Recurse -Force -Path $Dest -ErrorAction SilentlyContinue).Count
        return @{ ok=$true; path=$Dest; files=$count }
    } catch {
        return @{ ok=$false; error=$_.Exception.Message }
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------- routing

function Handle-Request {
    param($Context)

    $req  = $Context.Request
    $path = $req.Url.AbsolutePath.TrimEnd('/')
    if ($path -eq '') { $path = '/' }
    $method = $req.HttpMethod.ToUpperInvariant()
    $peer   = ''
    try { $peer = $req.RemoteEndPoint.Address.ToString() } catch { }

    # Self-description first: it must answer before the caller owns any secret.
    # IP restriction (-AllowFrom) still applies; the password requirement does not.
    if ($path -eq '/howto' -or $path -eq '/help' -or $path -eq '/') {
        if (-not (Test-IpAllowed $Context)) {
            Write-Log "DENY howto from $peer"
            Send-Json $Context 403 @{ ok=$false; error='forbidden' }
            return
        }
        $fmt  = 'json'
        $lang = 'en'
        if ($req.Url.Query) {
            foreach ($part in $req.Url.Query.TrimStart('?').Split('&')) {
                if ($part -eq '') { continue }
                $kv = $part.Split('=')
                if ($kv[0] -eq 'format' -and $kv.Length -gt 1) { $fmt  = $kv[1].ToLowerInvariant() }
                if ($kv[0] -eq 'lang'   -and $kv.Length -gt 1) { $lang = $kv[1].ToLowerInvariant() }
            }
        }
        Write-Log "HOWTO from $peer format=$fmt lang=$lang"
        if ($fmt -eq 'md' -or $fmt -eq 'markdown' -or $fmt -eq 'text') {
            if ($lang -eq 'zh') {
                $zhFile = Join-Path $WorkDir 'HOWTO.zh.md'
                if (Test-Path $zhFile -PathType Leaf) {
                    Send-Bytes $Context 200 ([System.IO.File]::ReadAllBytes($zhFile)) 'text/markdown; charset=utf-8'
                    return
                }
            }
            Send-Text $Context 200 (Get-HowToMarkdown) 'text/markdown; charset=utf-8'
            return
        }
        Send-Json $Context 200 (Get-HowTo)
        return
    }

    # fail2ban gate: a locked-out IP never reaches auth (all protected endpoints).
    if (Test-Banned $peer) {
        Write-Log "BLOCKED $method $path from $peer (fail2ban lockout)"
        $bu = Get-BanUntil $peer
        Send-Json $Context 429 @{ ok=$false; code='throttled'; error='too many failed attempts; temporarily blocked';
                                  message='too many failed attempts; temporarily blocked';
                                  lockedUntil=$bu; hint='wait for the lockout to expire, or the administrator clears it via POST /fail' }
        return
    }

    if (-not (Test-RequestAuth $Context)) {
        # Record the failure, THEN check the ban table. Do not fold them into one
        # expression: Update-FailState returns nothing, and "-and" short-circuits on
        # $null so the ban check would never run on the triggering attempt.
        Update-FailState -Ip $peer -Action 'fail'
        $nowBanned = Test-Banned $peer
        Write-Log "DENY $method $path from $peer"
        if ($nowBanned) {
            Send-Json $Context 429 @{ ok=$false; code='throttled'; error='too many failed attempts; temporarily blocked';
                                      message='too many failed attempts; temporarily blocked';
                                      lockedUntil=(Get-BanUntil $peer); hint='wait for the lockout to expire' }
        } else {
            Send-Json $Context 403 @{ ok=$false; code='forbidden'; error='forbidden';
                                      message='forbidden';
                                      hint='password missing or wrong. Send it in HTTP header X-Agent-Token. GET /howto needs no password and explains everything.' }
        }
        return
    }

    # Successful auth: forget this IP's prior failures (no-op if it had none).
    Update-FailState -Ip $peer -Action 'ok'

    switch ($path) {

        '/health' {
            Send-Json $Context 200 @{ ok=$true; version=$AgentVersion; hostname=$env:COMPUTERNAME;
                                      time=(Get-Date).ToString('s'); peer=$peer }
            return
        }

        '/fail' {
            if ($method -eq 'GET') {
                Send-Json $Context 200 (Get-FailSummary)
                return
            }
            if ($method -eq 'POST') {
                $body = Read-Body $Context
                $o = ConvertFrom-JsonSafe $body
                if ($o -and $o.action -eq 'clear') {
                    Clear-FailAll
                    Send-Json $Context 200 (Get-FailSummary)
                    return
                }
                if ($o -and $o.action -eq 'unban' -and $o.ip) {
                    Update-FailState -Ip ([string]$o.ip) -Action 'ok'
                    Send-Json $Context 200 (Get-FailSummary)
                    return
                }
                Send-Json $Context 400 @{ ok=$false; error='expect {"action":"clear"} or {"action":"unban","ip":"x.x.x.x"}' }
                return
            }
            Send-Json $Context 405 @{ ok=$false; error='GET or POST required' }
            return
        }

        '/info' {
            Write-Log ('>> INFO <- ' + $peer)
            Send-Json $Context 200 (Get-SystemInfo)
            return
        }

        '/exec' {
            if ($method -ne 'POST') { Send-Json $Context 405 @{ ok=$false; error='POST required' }; return }
            $body = Read-Body $Context
            $p    = ConvertFrom-JsonSafe $body
            if ($p -eq $null -or -not $p.cmd) { Send-Json $Context 400 @{ ok=$false; error='missing cmd' }; return }

            $shell = 'cmd'
            if ($p.shell) { $shell = [string]$p.shell }
            $to = $DefaultTimeout
            if ($p.timeout) { $to = [int]$p.timeout }
            $cwd = ''
            if ($p.cwd) { $cwd = [string]$p.cwd }

            $cmdText = [string]$p.cmd
            Write-Log ('>> EXEC ' + $shell + ' <- ' + $peer + ' :: ' + (Shorten $cmdText 400))
            $res = Invoke-ShellText -CommandText $cmdText -Shell $shell -TimeoutSec $to -Cwd $cwd
            Write-Result 'EXEC' $res
            Send-Json $Context 200 $res
            return
        }

        '/script' {
            if ($method -ne 'POST') { Send-Json $Context 405 @{ ok=$false; error='POST required' }; return }
            $body = Read-Body $Context
            if ([string]::IsNullOrWhiteSpace($body)) { Send-Json $Context 400 @{ ok=$false; error='empty body' }; return }

            $shell = 'powershell'
            $to    = $DefaultTimeout
            if ($req.Url.Query) {
                foreach ($part in $req.Url.Query.TrimStart('?').Split('&')) {
                    $kv = $part.Split('=')
                    if ($kv[0] -eq 'shell'   -and $kv.Length -gt 1) { $shell = [System.Net.WebUtility]::UrlDecode($kv[1]) }
                    if ($kv[0] -eq 'timeout' -and $kv.Length -gt 1) { try { $to = [int]$kv[1] } catch { } }
                }
            }
            $lineCount = ($body -split "`n").Count
            Write-Log ('>> SCRIPT ' + $shell + ' <- ' + $peer + ', ' + $lineCount + ' lines :: ' + (Shorten $body 200))
            $res = Invoke-ShellText -CommandText $body -Shell $shell -TimeoutSec $to
            Write-Result 'SCRIPT' $res
            Send-Json $Context 200 $res
            return
        }

        '/file' {
            if ($method -eq 'GET') {
                $q = $req.Url.Query.TrimStart('?')
                $target = ''
                foreach ($part in $q.Split('&')) {
                    $kv = $part.Split('=')
                    if ($kv[0] -eq 'path' -and $kv.Length -gt 1) { $target = [System.Net.WebUtility]::UrlDecode(($part.Substring(5))) }
                }
                if ([string]::IsNullOrWhiteSpace($target) -or -not (Test-Path $target -PathType Leaf)) {
                    Send-Json $Context 404 @{ ok=$false; error='file not found: ' + $target }
                    return
                }
                Write-Log ('>> DOWNLOAD ' + $target + ' -> ' + $peer)
                $bytes = [System.IO.File]::ReadAllBytes($target)
                Write-Log ('<< DOWNLOAD ' + $bytes.Length + ' bytes')
                Send-Bytes $Context 200 $bytes
                return
            }
            if ($method -eq 'POST') {
                $p = ConvertFrom-JsonSafe (Read-Body $Context)
                if ($p -eq $null -or -not $p.path -or $p.content -eq $null) {
                    Send-Json $Context 400 @{ ok=$false; error='need path + content' }
                    return
                }
                $target = [string]$p.path
                $enc = 'base64'; if ($p.encoding) { $enc = [string]$p.encoding }
                Write-Log ('>> UPLOAD ' + $target + ' <- ' + $peer)
                try {
                    if ($enc -eq 'base64') { $bytes = [Convert]::FromBase64String([string]$p.content) }
                    else                   { $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$p.content) }
                    $parent = Split-Path -Parent $target
                    if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
                    [System.IO.File]::WriteAllBytes($target, $bytes)
                    Write-Log ('<< UPLOAD ' + $target + ' ' + $bytes.Length + ' bytes <- ' + $peer)
                    Send-Json $Context 200 @{ ok=$true; path=$target; bytes=$bytes.Length }
                } catch {
                    Send-Json $Context 500 @{ ok=$false; error=$_.Exception.Message }
                }
                return
            }
            Send-Json $Context 405 @{ ok=$false; error='GET/POST only' }
            return
        }

        '/tail' {
            $target = ''; $lines = 200
            foreach ($part in $req.Url.Query.TrimStart('?').Split('&')) {
                if ($part.StartsWith('path='))  { $target = [System.Net.WebUtility]::UrlDecode($part.Substring(5)) }
                if ($part.StartsWith('lines=')) { try { $lines = [int]$part.Substring(6) } catch { } }
            }
            if ([string]::IsNullOrWhiteSpace($target) -or -not (Test-Path $target -PathType Leaf)) {
                Send-Json $Context 404 @{ ok=$false; error='file not found: ' + $target }
                return
            }
            Write-Log ('>> TAIL ' + $target + ' lines=' + $lines + ' <- ' + $peer)
            try {
                $all = [System.IO.File]::ReadAllLines($target, [System.Text.Encoding]::UTF8)
                $n   = [Math]::Min($lines, $all.Length)
                $sel = $all[($all.Length - $n)..($all.Length - 1)]
                Send-Json $Context 200 @{ ok=$true; path=$target; totalLines=$all.Length;
                                          content = ($sel -join "`n") }
            } catch {
                Send-Json $Context 500 @{ ok=$false; error=$_.Exception.Message }
            }
            return
        }

        '/ls' {
            $target = '.'
            foreach ($part in $req.Url.Query.TrimStart('?').Split('&')) {
                if ($part.StartsWith('path=')) { $target = [System.Net.WebUtility]::UrlDecode($part.Substring(5)) }
            }
            if ([string]::IsNullOrWhiteSpace($target)) { $target = '.' }
            if (-not (Test-Path $target)) { Send-Json $Context 404 @{ ok=$false; error='not found: ' + $target }; return }
            Write-Log ('>> LS ' + $target + ' <- ' + $peer)
            $items = @()
            Get-ChildItem -Force -Path $target -ErrorAction SilentlyContinue | ForEach-Object {
                $items += (@{
                    name = $_.Name
                    dir  = $_.PSIsContainer
                    size = if ($_.PSIsContainer) { 0 } else { $_.Length }
                    mtime= $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
                })
            }
            Send-Json $Context 200 @{ ok=$true; path=(Resolve-Path $target).Path; items=$items }
            return
        }

        '/process' {
            if ($method -eq 'GET') {
                $name = ''
                foreach ($part in $req.Url.Query.TrimStart('?').Split('&')) {
                    if ($part.StartsWith('name=')) { $name = [System.Net.WebUtility]::UrlDecode($part.Substring(5)) }
                }
                Write-Log ('>> PROCESS list <- ' + $peer)
                Send-Json $Context 200 @{ ok=$true; count=(@(Get-ProcessList -Filter $name)).Count; items=(Get-ProcessList -Filter $name) }
                return
            }
            if ($method -eq 'POST') {
                $p = ConvertFrom-JsonSafe (Read-Body $Context)
                if ($p -eq $null) { Send-Error $Context 400 'bad_request' 'invalid JSON body'; return }
                $act = ''; if ($p.action) { $act = [string]$p.action }
                $procId = 0; if ($p.pid) { $procId = [int]$p.pid }
                $nme = ''; if ($p.name)   { $nme = [string]$p.name }
                if ($act -ne 'kill') { Send-Error $Context 400 'bad_request' 'action must be kill' ; return }
                Write-Log ('>> KILL pid=' + $procId + ' name=' + $nme + ' <- ' + $peer)
                $res = Invoke-KillProcess -ProcessId $procId -Name $nme
                Send-Json $Context $(if ($res.ok) { 200 } else { 400 }) $res
                return
            }
            Send-Error $Context 405 'method_not_allowed' 'GET/POST only'
            return
        }

        '/service' {
            if ($method -eq 'GET') {
                $name = ''
                foreach ($part in $req.Url.Query.TrimStart('?').Split('&')) {
                    if ($part.StartsWith('name=')) { $name = [System.Net.WebUtility]::UrlDecode($part.Substring(5)) }
                }
                Write-Log ('>> SERVICE list <- ' + $peer)
                Send-Json $Context 200 @{ ok=$true; count=(@(Get-ServiceList -Filter $name)).Count; items=(Get-ServiceList -Filter $name) }
                return
            }
            if ($method -eq 'POST') {
                $p = ConvertFrom-JsonSafe (Read-Body $Context)
                if ($p -eq $null) { Send-Error $Context 400 'bad_request' 'invalid JSON body'; return }
                $nme  = ''; if ($p.name)  { $nme  = [string]$p.name }
                $act  = ''; if ($p.action){ $act  = [string]$p.action }
                Write-Log ('>> SERVICE ' + $act + ' ' + $nme + ' <- ' + $peer)
                $res = Invoke-ServiceControl -Name $nme -Action $act
                Send-Json $Context $(if ($res.ok) { 200 } else { 400 }) $res
                return
            }
            Send-Error $Context 405 'method_not_allowed' 'GET/POST only'
            return
        }

        '/zip' {
            if ($method -ne 'GET') { Send-Error $Context 405 'method_not_allowed' 'GET only'; return }
            $target = ''
            foreach ($part in $req.Url.Query.TrimStart('?').Split('&')) {
                if ($part.StartsWith('path=')) { $target = [System.Net.WebUtility]::UrlDecode($part.Substring(5)) }
            }
            if ([string]::IsNullOrWhiteSpace($target) -or -not (Test-Path $target)) {
                Send-Error $Context 404 'not_found' 'path not found: ' $target
                return
            }
            Write-Log ('>> ZIP ' + $target + ' <- ' + $peer)
            $r = Get-ZipBytes -Path $target
            if (-not $r.ok) { Send-Error $Context 500 'zip_failed' $r.error; return }
            Write-Log ('<< ZIP ' + $r.bytes.Length + ' bytes')
            Send-Bytes $Context 200 $r.bytes 'application/zip'
            return
        }

        '/unzip' {
            if ($method -ne 'POST') { Send-Error $Context 405 'method_not_allowed' 'POST only'; return }
            $p = ConvertFrom-JsonSafe (Read-Body $Context)
            if ($p -eq $null -or -not $p.path -or $p.content -eq $null) {
                Send-Error $Context 400 'bad_request' 'need path + content (base64 zip)'
                return
            }
            $dest = [string]$p.path
            $enc  = 'base64'; if ($p.encoding) { $enc = [string]$p.encoding }
            Write-Log ('>> UNZIP ' + $dest + ' <- ' + $peer)
            try {
                if ($enc -eq 'base64') { $bytes = [Convert]::FromBase64String([string]$p.content) }
                else                   { $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$p.content) }
            } catch {
                Send-Error $Context 400 'bad_request' 'content is not valid base64' $_.Exception.Message
                return
            }
            $res = Expand-ZipBytes -Dest $dest -Bytes $bytes
            if (-not $res.ok) { Send-Error $Context 500 'unzip_failed' $res.error; return }
            Write-Log ('<< UNZIP ' + $dest + ' ' + $res.files + ' files')
            Send-Json $Context 200 $res
            return
        }

        '/audit' {
            if ($method -ne 'GET') { Send-Error $Context 405 'method_not_allowed' 'GET only'; return }
            $lines = 100
            foreach ($part in $req.Url.Query.TrimStart('?').Split('&')) {
                if ($part.StartsWith('lines=')) { try { $lines = [int]$part.Substring(6) } catch { } }
            }
            Write-Log ('>> AUDIT lines=' + $lines + ' <- ' + $peer)
            # Build the JSON manually. ConvertTo-Json in Windows PowerShell 5.1 can loop
            # forever on a string array sliced out of Get-Content, which would deadlock
            # the single-threaded listener. Manual escaping is safe for any log text.
            $entries = New-Object System.Collections.ArrayList
            if (-not $NoLog -and (Test-Path $LogFile -PathType Leaf)) {
                $all = @(Get-Content -Path $LogFile -Encoding UTF8 -ErrorAction SilentlyContinue)
                $n   = [Math]::Min($lines, $all.Count)
                for ($i = ($all.Count - $n); $i -le ($all.Count - 1); $i++) { [void]$entries.Add([string]$all[$i]) }
            }
            $sb = New-Object System.Text.StringBuilder
            [void]$sb.Append('{"ok":true,"log":')
            [void]$sb.Append((ConvertTo-JsonString ([string]$LogFile)))
            [void]$sb.Append(',"enabled":')
            [void]$sb.Append($(if (-not $NoLog) { 'true' } else { 'false' }))
            [void]$sb.Append(',"count":')
            [void]$sb.Append($entries.Count)
            [void]$sb.Append(',"entries":[')
            for ($i = 0; $i -lt $entries.Count; $i++) {
                if ($i -gt 0) { [void]$sb.Append(',') }
                [void]$sb.Append((ConvertTo-JsonString ([string]$entries[$i])))
            }
            [void]$sb.Append(']}')
            Send-JsonRaw $Context 200 $sb.ToString()
            return
        }

        '/stop' {
            if ($method -ne 'POST') { Send-Json $Context 405 @{ ok=$false; error='POST required' }; return }
            Write-Log ('>> STOP <- ' + $peer)
            Send-Json $Context 200 @{ ok=$true; stopping=$true }
            $script:StopRequested = $true
            # The accept loop now runs in a *different* runspace thread, so the in-process
            # flag alone cannot stop it. Drop a stop-file the listener polls every 400ms.
            try { New-Item -ItemType File -Path (Join-Path $script:WorkDir 'agent.stop') -Force -ErrorAction SilentlyContinue | Out-Null } catch { }
            return
        }

        # Self-extend: an operator (or the AI itself) writes a NEW agent.ps1 over the
        # current file, then POSTs /reload. This writes a small launcher that kills the
        # running copy and starts the new one with the SAME boot arguments. This is the
        # "live adaptive boost" mechanism: add features by editing the script, then reload.
        '/reload' {
            if ($method -ne 'POST') { Send-Error $Context 405 'method_not_allowed' 'POST only'; return }
            Write-Log ('>> RELOAD <- ' + $peer)
            $relFile = Join-Path $JobDir ('reload-' + [guid]::NewGuid().ToString('N') + '.ps1')
            $b = $script:Boot
            $argLines = New-Object System.Collections.ArrayList
            [void]$argLines.Add("'-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File'," + "'$($b.script)'")
            [void]$argLines.Add("'-Port'," + "'$($b.port)'")
            [void]$argLines.Add("'-WorkDir'," + "'$($b.workDir)'")
            [void]$argLines.Add("'-BindAddress'," + "'$($b.bind)'")
            foreach ($a in $b.allow) { [void]$argLines.Add("'-AllowFrom'," + "'$a'") }
            if ($b.cert) { [void]$argLines.Add("'-CertThumbprint'," + "'$($b.cert)'") }
            if ($b.noLog) { [void]$argLines.Add("'-NoLog'") }
            $argJoin = $argLines -join ','
            $rel = @"
`$ErrorActionPreference='SilentlyContinue'
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { `$_.CommandLine -and (`$_.CommandLine -match 'agent\.ps1') } | ForEach-Object { Stop-Process -Id `$_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 2
`$ps='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
`$a=@($argJoin)
Start-Process -FilePath `$ps -ArgumentList `$a -WindowStyle Hidden
"@
            [System.IO.File]::WriteAllText($relFile, $rel, (New-Object System.Text.UTF8Encoding($true)))
            # Start the reloader detached; it will kill us and bring up the new agent.
            $relB64 = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes(('& "' + $relFile + '"')))
            Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
                -ArgumentList ('-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand',$relB64) -WindowStyle Hidden | Out-Null
            Send-Json $Context 200 @{ ok=$true; reloading=$true; hint='this connection will drop; reconnect after ~6s' }
            return
        }

        default {
            Send-Error $Context 404 'not_found' ('unknown endpoint ' + $path)
            return
        }
    }
}

# ---------------------------------------------------------------- main loop
#
# v2.0 concurrency fix: each request is handled in its OWN runspace (thread), so
# a slow or hung command (e.g. a child process that keeps a pipe open) can no
# longer block the accept loop. /health and every other endpoint stay responsive.
# The accept loop polls with BeginGetContext (400ms), reaps finished workers, and
# checks the /stop stop-file between requests. Worker runspaces dot-source this
# same file with -ThreadWorker, which loads all functions/state but skips this block.

if (-not $ThreadWorker) {

    $script:StopRequested = $false
    $scheme = 'http'
    if ($CertThumbprint -ne '') { $scheme = 'https' }
    $prefix = $scheme + '://' + $BindAddress + ':' + $Port + '/'
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add($prefix)
    $listener.IgnoreWriteExceptions = $true

    try {
        $listener.Start()
    } catch {
        Write-Log "FATAL cannot listen on $prefix : $($_.Exception.Message)"
        Write-Host "FATAL: cannot listen on $prefix"
        Write-Host "      $($_.Exception.Message)"
        Write-Host "Hint: run install-agent.bat as Administrator (it reserves the URL with netsh)."
        exit 1
    }

    Write-Log "START pid=$PID prefix=$prefix token=$($(if($Token -ne ''){'yes'}else{'no'})) allowFrom=$($AllowFrom -join ',')"
    Write-Host "agent listening on $prefix"

    $script:AgentFile   = $MyInvocation.MyCommand.Path
    $script:StopFile    = Join-Path $WorkDir 'agent.stop'
    $script:Pending     = @()
    if (Test-Path $script:StopFile) { Remove-Item $script:StopFile -Force -ErrorAction SilentlyContinue }

    # Hand a request + the listener's boot state to a fresh runspace, then run
    # Handle-Request inside it. Fire-and-forget: the accept loop keeps running.
    $script:WorkerScript = @'
param($WorkerCtx)
if (-not $WorkerCtx -or -not $WorkerCtx.ctx) { return }
. $WorkerCtx.path -Port $WorkerCtx.port -Token $WorkerCtx.token `
    -AllowFrom $WorkerCtx.allow -WorkDir $WorkerCtx.workDir `
    -MaxTimeout $WorkerCtx.maxTimeout -BindAddress $WorkerCtx.bind -ThreadWorker
Handle-Request $WorkerCtx.ctx
'@

    function Start-ContextHandler {
        param([System.Net.HttpListenerContext]$Context)
        $rs = $null; $ps = $null
        try {
            $wk = @{
                ctx = $Context
                path = $script:AgentFile
                port = $Port; token = $Token; bind = $BindAddress
                allow = @($AllowFrom); workDir = $WorkDir; maxTimeout = $script:MaxTimeout
            }
            $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
            $rs.Open()
            $ps = [System.Management.Automation.PowerShell]::Create()
            $ps.Runspace = $rs
            [void] $ps.AddScript($script:WorkerScript)
            [void] $ps.AddArgument($wk)
            $sync = $ps.BeginInvoke()
            $script:Pending = @($script:Pending + @{ ps=$ps; rs=$rs; h=$sync })
        } catch {
            Write-Log "ERROR dispatch failed: $($_.Exception.Message)"
            try { Send-Json $Context 500 @{ ok=$false; error='dispatch failed: ' + $_.Exception.Message } } catch { }
            try { $rs.Dispose() } catch { }
            try { $ps.Dispose() } catch { }
        }
    }

    # Reap finished workers: EndInvoke, then dispose the runspace to free the thread.
    function Get-Outstanding {
        if ($script:Pending.Count -eq 0) { return }
        $done = @($script:Pending | Where-Object { $_.h.IsCompleted })
        foreach ($d in $done) {
            try { [void] $d.ps.EndInvoke($d.h) } catch { }
            try { $d.ps.Dispose() } catch { }
            try { $d.rs.Dispose() } catch { }
        }
        if ($done.Count) { $script:Pending = @($script:Pending | Where-Object { $_.h.IsCompleted -eq $false }) }
    }

    $script:Accept = $listener.BeginGetContext($null, $null)
    while ($true) {
        try { if (-not $listener.IsListening) { break } } catch { break }
        Get-Outstanding
        if (Test-Path $script:StopFile -PathType Leaf) { break }
        try {
            if ($script:Accept.AsyncWaitHandle.WaitOne(400)) {
                $ctx = $null
                try { $ctx = $listener.EndGetContext($script:Accept) } catch { $ctx = $null }
                if ($null -ne $ctx) { Start-ContextHandler $ctx }
                $script:Accept = $listener.BeginGetContext($null, $null)
            } else {
                Start-Sleep -Milliseconds 60
            }
        } catch {
            if ($listener.IsListening) { Start-Sleep -Milliseconds 200 }
        }
    }

    try { $listener.Stop(); $listener.Close() } catch { }
    Remove-Item $script:StopFile -Force -ErrorAction SilentlyContinue
    Write-Log "STOPPED"
    Write-Host "agent stopped"
}
