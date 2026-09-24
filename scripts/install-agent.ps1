<#
  install-agent.ps1 - install / reconfigure / start server-agent.ps1
  Run as Administrator.

  Every native command goes through Invoke-Native so that a harmless non-zero
  exit (e.g. "schtasks /delete" when the task does not exist yet) cannot abort
  the whole install. Each step is verified and reported separately.
#>

param(
    [int]    $Port      = 8765,
    [string] $AllowFrom = '',
    [string] $Password  = '',
    [switch] $AskPassword,
    [string] $TaskName  = 'RemoteOpsAgent',
    [switch] $Uninstall,
    [switch] $NoTask
)

# NOTE: deliberately NOT 'Stop' - native commands legitimately return non-zero.
$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

$dir       = Split-Path -Parent $MyInvocation.MyCommand.Path
$agentPs1  = Join-Path $dir 'agent.ps1'
$tokenFile = Join-Path $dir 'token.txt'

function Write-Step($msg, $color) {
    if (-not $color) { $color = 'Gray' }
    Write-Host ('  ' + $msg) -ForegroundColor $color
}

function Invoke-Native {
    param([scriptblock]$Command)
    $out = (& $Command) 2>&1 | Out-String
    return @{ exit = $LASTEXITCODE; out = $out.Trim() }
}

function Assert-Admin {
    $isAdmin = $false
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $isAdmin = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
                     [Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { }
    if (-not $isAdmin) {
        Write-Host 'ERROR: this script must be run as Administrator.' -ForegroundColor Red
        Write-Host '       Right-click install-agent.bat -> Run as administrator.'
        exit 1
    }
}

function Stop-AgentProcess {
    # Match ONLY "...\agent.ps1". A loose '*agent.ps1*' would also match this
    # very installer (install-agent.ps1) and kill it mid-run.
    $self = $PID
    Get-WmiObject Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -ne $self -and $_.CommandLine -and ($_.CommandLine -match '[\\/]agent\.ps1') } |
        ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }
}

function Remove-Agent {
    param([string]$Name, [int]$P)
    Write-Host 'Stopping agent process ...'
    Stop-AgentProcess
    Write-Host "Deleting scheduled task '$Name' ..."
    $r = Invoke-Native { & schtasks.exe /delete /tn $Name /f }
    Write-Step ("exit=$($r.exit) $($r.out)") $(if ($r.exit -eq 0) { 'Green' } else { 'Yellow' })
    Write-Host 'Removing urlacl ...'
    $r = Invoke-Native { & netsh.exe http delete urlacl url=("http://+:{0}/" -f $P) }
    Write-Step ("exit=$($r.exit)") $(if ($r.exit -eq 0) { 'Green' } else { 'Yellow' })
    Write-Host 'Removing firewall rule ...'
    $r = Invoke-Native { & netsh.exe advfirewall firewall delete rule name=("RemoteOpsAgent-{0}" -f $P) }
    Write-Step ("exit=$($r.exit)") $(if ($r.exit -eq 0) { 'Green' } else { 'Yellow' })
    Write-Host 'Uninstalled.' -ForegroundColor Cyan
}

Assert-Admin

if ($Uninstall) { Remove-Agent -Name $TaskName -P $Port; exit 0 }

if (-not (Test-Path $agentPs1)) {
    Write-Host "ERROR: agent.ps1 not found at $agentPs1" -ForegroundColor Red
    exit 1
}

# ---- password / token -------------------------------------------------------
function ToPlain([System.Security.SecureString] $sec) {
    if ($sec -eq $null) { return '' }
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringAuto($b) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

if ($AskPassword) {
    # Read-Host throws under -NonInteractive, which used to abort the install.
    if (-not [Environment]::UserInteractive) {
        Write-Host 'WARNING: PowerShell is non-interactive, cannot prompt for a password.' -ForegroundColor Yellow
        $existing = ''
        if (Test-Path $tokenFile) { $existing = (Get-Content $tokenFile -Raw).Trim() }
        if ($existing -ne '') {
            $Password = $existing
            Write-Host ('         Reusing the password already in token.txt: ' + $Password) -ForegroundColor Yellow
        } else {
            Write-Host 'ERROR: no password supplied and token.txt is empty.' -ForegroundColor Red
            Write-Host ('       powershell -ExecutionPolicy Bypass -File "' + $MyInvocation.MyCommand.Path + '" -Port ' + $Port + ' -Password "your-password"') -ForegroundColor Red
            exit 1
        }
    } else {
        $s1 = Read-Host 'Set connection password (input hidden)' -AsSecureString
        $p1 = ToPlain $s1
        if ($p1 -eq '') { Write-Host 'ERROR: password cannot be empty.' -ForegroundColor Red; exit 1 }
        $s2 = Read-Host 'Confirm password (input hidden)' -AsSecureString
        if ((ToPlain $s2) -ne $p1) {
            Write-Host 'ERROR: the two passwords do not match. Nothing was changed.' -ForegroundColor Red
            exit 1
        }
        $Password = $p1
        Write-Host 'Password accepted.' -ForegroundColor Green
    }
}

if ($Password -ne '') {
    $token = $Password
    Set-Content -Path $tokenFile -Value $token -Encoding ASCII
    Write-Host 'Using the password you supplied.'
} elseif (Test-Path $tokenFile) {
    $token = (Get-Content $tokenFile -Raw).Trim()
    Write-Host 'Using existing password from token.txt'
} else {
    $bytes = New-Object 'Byte[]' 32
    (New-Object System.Security.Cryptography.RNGCryptoServiceProvider).GetBytes($bytes)
    $token = -join ($bytes | ForEach-Object { $_.ToString('x2') })
    Set-Content -Path $tokenFile -Value $token -Encoding ASCII
    Write-Host "Generated a random password -> token.txt"
}

# ---- url acl ----------------------------------------------------------------
$url = 'http://+:' + $Port + '/'
Write-Host ''
Write-Host "Reserving URL $url ..."
$r = Invoke-Native { & netsh.exe http delete urlacl url=$url }
$r = Invoke-Native { & netsh.exe http add urlacl url=$url user='Everyone' }
if ($r.exit -eq 0) { Write-Step 'OK' 'Green' } else { Write-Step ("FAILED exit=$($r.exit): $($r.out)") 'Red' }
$verify = Invoke-Native { & netsh.exe http show urlacl url=$url }
if ($verify.out -match [regex]::Escape($url)) { Write-Step 'verified in urlacl list' 'Green' }
else { Write-Step 'NOT found in urlacl list - agent may fail to bind' 'Red' }

# ---- firewall ---------------------------------------------------------------
$ruleName = 'RemoteOpsAgent-' + $Port
Write-Host "Opening firewall TCP/$Port ..."
$r = Invoke-Native { & netsh.exe advfirewall firewall delete rule name=$ruleName }
$r = Invoke-Native { & netsh.exe advfirewall firewall add rule name=$ruleName dir=in action=allow protocol=TCP localport=$Port }
if ($r.exit -eq 0) { Write-Step 'OK' 'Green' } else { Write-Step ("FAILED exit=$($r.exit): $($r.out)") 'Red' }
$fwv = Invoke-Native { & netsh.exe advfirewall firewall show rule name=$ruleName }
if ($fwv.out -match 'RemoteOpsAgent') { Write-Step 'verified in firewall rules' 'Green' }
else { Write-Step 'rule NOT visible - check Windows Firewall service' 'Yellow' }

# ---- scheduled task ---------------------------------------------------------
# Build the launch line. token.txt is read by the agent itself, so the token
# never has to appear on the command line.
$tr = 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $agentPs1 +
      '" -Port ' + $Port + ' -WorkDir "' + $dir + '"'
if ($AllowFrom -ne '') { $tr += ' -AllowFrom ' + $AllowFrom }

Stop-AgentProcess
Start-Sleep -Seconds 1

if (-not $NoTask) {
    Write-Host "Registering scheduled task '$TaskName' (SYSTEM, onstart) ..."
    $r = Invoke-Native { & schtasks.exe /delete /tn $TaskName /f }   # non-fatal if absent
    $r = Invoke-Native { & schtasks.exe /create /tn $TaskName /tr $tr /sc onstart /ru SYSTEM /RL HIGHEST /f }
    if ($r.exit -ne 0) {
        Write-Step ("with /RL HIGHEST failed (exit=$($r.exit)): $($r.out)") 'Yellow'
        $r = Invoke-Native { & schtasks.exe /create /tn $TaskName /tr $tr /sc onstart /ru SYSTEM /f }
    }
    if ($r.exit -eq 0) { Write-Step 'OK' 'Green' }
    else { Write-Step ("FAILED exit=$($r.exit): $($r.out)") 'Red' }

    $q = Invoke-Native { & schtasks.exe /query /tn $TaskName /fo LIST }
    if ($q.exit -eq 0 -and $q.out -match $TaskName) { Write-Step 'task visible in scheduler' 'Green' }
    else { Write-Step 'task NOT visible in scheduler' 'Red' }

    Write-Host "Starting task now ..."
    $r = Invoke-Native { & schtasks.exe /run /tn $TaskName }
    if ($r.exit -eq 0) { Write-Step 'OK' 'Green' } else { Write-Step ("exit=$($r.exit): $($r.out)") 'Yellow' }
    Start-Sleep -Seconds 3
}

# ---- verify the agent is actually listening ---------------------------------
Write-Host ''
Write-Host ('Probing http://127.0.0.1:' + $Port + '/health ...')
$alive = $false
$lastErr = ''
for ($i = 0; $i -lt 12; $i++) {
    try {
        $req = [System.Net.HttpWebRequest]::Create('http://127.0.0.1:' + $Port + '/health')
        $req.Headers['X-Agent-Token'] = $token
        $req.Timeout = 3000
        $resp = $req.GetResponse()
        $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $body = $sr.ReadToEnd(); $sr.Close(); $resp.Close()
        $alive = $true
        Write-Step ("OK  " + $body) 'Green'
        break
    } catch {
        $lastErr = $_.Exception.Message
        Start-Sleep -Seconds 1
    }
}
if (-not $alive) {
    Write-Step ("agent is NOT answering locally: $lastErr") 'Red'
    Write-Step 'Try: start-agent.bat  (runs the agent in the foreground for a smoke test)' 'Yellow'
}

# ---- report -----------------------------------------------------------------
$ips = @()
Get-WmiObject Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -ErrorAction SilentlyContinue |
    ForEach-Object { foreach ($a in $_.IPAddress) { if ($a -notmatch ':') { $ips += $a } } }

Write-Host ''
Write-Host '================= INSTALL SUMMARY =================' -ForegroundColor Cyan
Write-Host ("Token      : " + $token)
Write-Host ("Port       : " + $Port)
Write-Host ("Server IPs : " + ($ips -join ', '))
Write-Host ("WorkDir    : " + $dir)
Write-Host ("Agent alive: " + $alive)
foreach ($ip in $ips) { Write-Host ("URL        : http://" + $ip + ":" + $Port + "/health") }
Write-Host '====================================================' -ForegroundColor Cyan
Write-Host ''
Write-Host 'Test from another machine:'
Write-Host ('  curl -H "X-Agent-Token: ' + $token + '" http://<SERVER-IP>:' + $Port + '/health')
Write-Host ''
