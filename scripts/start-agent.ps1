<#
  start-agent.ps1 - launch the agent right now as a detached hidden process.
  Does NOT need the scheduled task. Run as Administrator (URL reservation
  still has to exist: install-agent.bat does that, or this script does it too).

  Auth options:
    -Password 'xxx'   use your own passphrase as the connection secret
    -AskPassword      prompt for it (hidden input, asked twice)
    (neither)         reuse token.txt, or generate a random one

  UI language:
    -Lang zh          default; reads strings.zh.txt (UTF-8) beside this file
    -Lang en          force English

  Activity console:
    -NoWatch          do not open the live log window (watch-agent.ps1)
#>

param(
    [int]      $Port        = 8765,
    [string]   $Password    = '',
    [switch]   $AskPassword,
    [string]   $AllowFrom   = '',
    [string]   $BindAddress = '+',
    [string]   $Lang        = 'zh',
    [switch]   $NoWatch
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

$dir      = Split-Path -Parent $MyInvocation.MyCommand.Path
$agentPs1 = Join-Path $dir 'agent.ps1'
$psExe    = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

# ---------------------------------------------------------------- i18n
# lib-ui.ps1 is optional: if it is missing we fall back to English only,
# so deleting it can never stop the agent from starting.
$libUi = Join-Path $dir 'lib-ui.ps1'
if (Test-Path $libUi -PathType Leaf) {
    try { . $libUi } catch { $script:UiStrings = @{} }
} else {
    $script:UiStrings = @{}
}
if (-not (Get-Command T -ErrorAction SilentlyContinue)) {
    function T { param([string]$Key = '', [string]$Fallback = '') return $Fallback }
}
if (-not (Get-Command Import-UiStrings -ErrorAction SilentlyContinue)) {
    function Import-UiStrings { param([string]$Dir = '', [string]$Lang = 'zh') $script:UiStrings = @{} }
}
Import-UiStrings -Dir $dir -Lang $Lang

function ToPlain([System.Security.SecureString] $sec) {
    if ($sec -eq $null) { return '' }
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringAuto($b) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

function Get-LocalIpList {
    $list = @()
    Get-WmiObject Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -ErrorAction SilentlyContinue |
        ForEach-Object {
            foreach ($a in $_.IPAddress) {
                if ($a -notmatch ':' -and $a -ne '127.0.0.1') { $list += $a }
            }
        }
    return @($list | Where-Object { $_ -ne '' } | Select-Object -Unique)
}

function Get-PublicIp {
    # Best effort only. A locked-down server may have no outbound HTTP at all,
    # and that must never fail the launch - we just omit the public address.
    $urls = @('http://api.ipify.org', 'http://ifconfig.me/ip', 'http://icanhazip.com', 'http://myip.ipip.net')
    foreach ($u in $urls) {
        try {
            $r = Invoke-RestMethod -Uri $u -TimeoutSec 6 -ErrorAction Stop
            $m = [regex]::Match([string]$r, '\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}')
            if ($m.Success) { return $m.Value }
        } catch { }
    }
    return ''
}

<#
  Emits a ready-to-paste block that tells an AI assistant how to connect.
  Zero typing for the human: they just select it, copy, and paste into chat.

  The Chinese wording lives in paste-template.zh.txt and strings.zh.txt (UTF-8).
  They are read as TEXT and never go through a PowerShell string literal,
  because a .ps1 without a BOM is parsed as ANSI/GBK on PowerShell 5.1 and
  below - putting Chinese directly in this file would break the whole script.
  If the template is missing, an ASCII English block is used instead.
#>
function Write-AiHandoff {
    param(
        [int]    $Port,
        [string] $Password,
        [string] $Dir = ''
    )

    if ($Dir -eq '' -and $PSScriptRoot) { $Dir = $PSScriptRoot }

    $addrs = @(Get-LocalIpList)
    $pub   = Get-PublicIp
    if ($pub -ne '' -and ($addrs -notcontains $pub)) { $addrs += $pub }

    $urls = @()
    foreach ($a in $addrs) { $urls += ($a + ':' + $Port) }
    if ($urls.Count -eq 0) { $urls += ('<server-ip>:' + $Port) }

    $primary = ''
    if ($pub -ne '') { $primary = $pub }
    elseif ($addrs.Count -gt 0) { $primary = $addrs[0] }

    $urlList = ($urls -join ', ')
    $howto   = 'http://' + $primary + ':' + $Port + '/howto'

    Write-Host ''
    Write-Host ((T 'label.publicIp' 'Public IP detected') + ': ' + $(if ($pub -ne '') { $pub } else { (T 'label.noPublicIp' 'none (no outbound HTTP)') }))
    Write-Host ((T 'label.reachable' 'Reachable at') + '      : ' + $urlList)

    $text = $null
    $tpl  = ''
    if ($Dir -ne '') { $tpl = Join-Path $Dir 'paste-template.zh.txt' }
    if ($tpl -ne '' -and (Test-Path $tpl -PathType Leaf)) {
        try {
            $raw  = [System.IO.File]::ReadAllText($tpl, [System.Text.Encoding]::UTF8)
            $text = $raw.Replace('{{URLS}}', $urlList).Replace('{{HOWTO}}', $howto).Replace('{{PASSWORD}}', $Password)
        } catch { $text = $null }
    }
    if ($text -eq $null) {
        $text = 'Please connect to the Server Agent at: ' + $urlList + "`n`n" +
                'Then send a GET request to ' + $howto + ' (no password needed) to read the interface documentation.' + "`n`n" +
                'The connection password is: ' + $Password + "`n" +
                'Send it in the HTTP header X-Agent-Token on every request. A 403 forbidden means it is missing or wrong.'
    }

    Write-Host ''
    Write-Host (T 'handoff.begin' '================ COPY EVERYTHING BELOW ================') -ForegroundColor Cyan
    Write-Host $text
    Write-Host (T 'handoff.end' '================ COPY EVERYTHING ABOVE ================') -ForegroundColor Cyan
    Write-Host ''
    Write-Host (T 'handoff.paste' 'Paste that block to your AI assistant. It explains the whole protocol.') -ForegroundColor Yellow
    Write-Host (T 'handoff.secret' 'It contains the password - do not post it anywhere public.') -ForegroundColor Yellow

    if ($Dir -ne '') {
        try {
            $outFile = Join-Path $Dir 'AI-HANDOFF.txt'
            $utf8Bom = New-Object System.Text.UTF8Encoding($true)
            [System.IO.File]::WriteAllText($outFile, $text, $utf8Bom)
            Write-Host ((T 'handoff.savedTo' 'Also saved to:') + ' ' + $outFile) -ForegroundColor Gray
        } catch { }
    }
}

<#
  Opens a separate visible window that tails agent.log.
  It is a DIFFERENT process from the agent on purpose: closing this window
  must never stop the agent (people instinctively close console windows).
#>
function Start-WatchWindow {
    param([string]$Dir)

    $watchPs1 = Join-Path $Dir 'watch-agent.ps1'
    if (-not (Test-Path $watchPs1 -PathType Leaf)) { return $false }

    # Close a console left over from an earlier launch, otherwise every restart
    # leaves another window behind. This only ever matches watch-agent.ps1.
    Get-WmiObject Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and ($_.CommandLine -match 'watch-agent\.ps1') } |
        ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }

    try {
        Start-Process -FilePath $psExe `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $watchPs1, '-Dir', $Dir) `
            -WindowStyle Normal | Out-Null
        return $true
    } catch { return $false }
}

if (-not (Test-Path $agentPs1)) {
    Write-Host ('ERROR: agent.ps1 not found: ' + $agentPs1) -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------- password
$tokenFile = Join-Path $dir 'token.txt'

if ($AskPassword) {
    # Read-Host dies instantly under -NonInteractive ("Windows PowerShell is in
    # non-interactive mode"). That used to abort the whole launch and leave the
    # agent down, so detect it up front and fall back instead of crashing.
    if (-not [Environment]::UserInteractive) {
        Write-Host (T 'warn.nonInteractive' 'WARNING: PowerShell is non-interactive, cannot prompt for a password.') -ForegroundColor Yellow
        Write-Host ('         ' + (T 'warn.nonInteractiveHint' '(usually because the caller passed -NonInteractive)')) -ForegroundColor Yellow
        $existing = ''
        if (Test-Path $tokenFile) { $existing = (Get-Content $tokenFile -Raw).Trim() }
        if ($existing -ne '') {
            $Password = $existing
            Write-Host ('         ' + (T 'warn.reuseToken' 'Reusing the password already in token.txt:') + ' ' + $Password) -ForegroundColor Yellow
        } else {
            Write-Host (T 'err.noPassword' 'ERROR: no password supplied and token.txt is empty.') -ForegroundColor Red
            Write-Host (T 'err.runInstead' 'Run this instead:') -ForegroundColor Red
            Write-Host ('       powershell -ExecutionPolicy Bypass -File "' + $MyInvocation.MyCommand.Path + '" -Port ' + $Port + ' -Password "your-password"') -ForegroundColor Red
            exit 1
        }
    } else {
        $s1 = Read-Host (T 'ask.password1' 'Set connection password (input hidden)') -AsSecureString
        $p1 = ToPlain $s1
        if ($p1 -eq '') {
            Write-Host (T 'err.emptyPassword' 'ERROR: password cannot be empty.') -ForegroundColor Red
            exit 1
        }
        $s2 = Read-Host (T 'ask.password2' 'Confirm password (input hidden)') -AsSecureString
        $p2 = ToPlain $s2
        if ($p1 -ne $p2) {
            Write-Host (T 'err.mismatch' 'ERROR: the two passwords do not match. Nothing was changed.') -ForegroundColor Red
            exit 1
        }
        $Password = $p1
        Write-Host (T 'ok.passwordAccepted' 'Password accepted.') -ForegroundColor Green
    }
}

$token = $Password

if ($token -eq '') {
    # fall back to the existing token file
    if (Test-Path $tokenFile) { $token = (Get-Content $tokenFile -Raw).Trim() }
}
if ($token -eq '') {
    # last resort: generate a random one
    $bytes = New-Object 'Byte[]' 32
    (New-Object System.Security.Cryptography.RNGCryptoServiceProvider).GetBytes($bytes)
    $token = -join ($bytes | ForEach-Object { $_.ToString('x2') })
    Write-Host (T 'warn.generatedPassword' 'No password given - generated a random one.') -ForegroundColor Yellow
}

# The agent reads its secret from token.txt in its working dir, so a passphrase
# typed at launch just replaces the file contents. This keeps one source of truth
# and avoids putting the secret on the process command line.
Set-Content -Path $tokenFile -Value $token -Encoding ASCII

Write-Host ((T 'label.password' 'Password') + '   : ' + $token)
if ($AllowFrom -eq '') {
    Write-Host (T 'warn.noAllowFrom' 'WARNING: no -AllowFrom set, any host that knows the password is accepted.') -ForegroundColor Yellow
}

# make sure the URL is reserved (harmless if it already is)
$addUrl = 'http://+:' + $Port + '/'
Write-Host ((T 'label.urlReserve' 'Ensuring URL reservation') + ' ' + $addUrl + ' ...')
$o = (& netsh.exe http add urlacl url=$addUrl user='Everyone') 2>&1 | Out-String
if ($LASTEXITCODE -eq 0) {
    Write-Host ('  ' + (T 'ok.reserved' 'reserved')) -ForegroundColor Green
} else {
    # On a second run netsh fails with a localized "already exists" error
    # (183 on Chinese Windows). That is success, not failure - so verify the
    # reservation is actually there instead of printing a scary message.
    $show = (& netsh.exe http show urlacl url=$addUrl) 2>&1 | Out-String
    if ($show -match [regex]::Escape($addUrl)) {
        Write-Host ('  ' + (T 'ok.alreadyReserved' 'already reserved (nothing to do)')) -ForegroundColor Green
    } else {
        Write-Host ('  ' + (T 'warn.reserveFailed' 'WARNING: could not reserve the URL:') + ' ' + $o.Trim()) -ForegroundColor Yellow
        Write-Host ('           ' + (T 'warn.needAdmin' 'Start this script as Administrator.')) -ForegroundColor Yellow
    }
}

# kill any previous instance
Write-Host (T 'label.stopping' 'Stopping any previous agent ...')
# Match ONLY "...\agent.ps1" - a loose '*agent.ps1*' would match start-agent.ps1
# (this very script) and kill it.
$self = $PID
Get-WmiObject Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessId -ne $self -and $_.CommandLine -and ($_.CommandLine -match '[\\/]agent\.ps1') } |
    ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }
Start-Sleep -Seconds 1

$argList = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass',
             '-File', $agentPs1, '-Port', $Port, '-WorkDir', $dir, '-BindAddress', $BindAddress)
if ($AllowFrom -ne '') { $argList += @('-AllowFrom', $AllowFrom) }

Write-Host (T 'label.launching' 'Launching agent (detached, hidden) ...')
$p = Start-Process -FilePath $psExe -ArgumentList $argList -WindowStyle Hidden -PassThru
Write-Host ('  ' + (T 'label.pid' 'pid=') + $p.Id) -ForegroundColor Green

Write-Host ''
Write-Host (T 'label.probing' 'Probing health ...')
$alive = $false
for ($i = 0; $i -lt 15; $i++) {
    Start-Sleep -Seconds 1
    try {
        $req = [System.Net.HttpWebRequest]::Create('http://127.0.0.1:' + $Port + '/health')
        if ($token) { $req.Headers['X-Agent-Token'] = $token }
        $req.Timeout = 3000
        $resp = $req.GetResponse()
        $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $body = $sr.ReadToEnd(); $sr.Close(); $resp.Close()
        Write-Host ('  ' + (T 'ok.probe' 'OK') + '  ' + $body) -ForegroundColor Green
        $alive = $true
        break
    } catch { }
}
if (-not $alive) {
    Write-Host ('  ' + (T 'err.notAnswering' 'agent did not answer. Run watch-agent.bat to see the log.')) -ForegroundColor Red
    exit 2
}

Write-Host ''
Write-Host ((T 'label.localIps' 'Server IPs (local)') + ': ' + ((Get-LocalIpList) -join ', '))
Write-Host ((T 'label.password' 'Password') + '          : ' + $token)
Write-Host (T 'ok.running' 'Agent is running.')

# --------------------------------------------------- copy-paste handoff block
Write-AiHandoff -Port $Port -Password $token -Dir $dir

# --------------------------------------------------- live activity console
if (-not $NoWatch) {
    if (Start-WatchWindow -Dir $dir) {
        Write-Host (T 'watch.opened' 'Activity console opened. Closing that window does NOT stop the agent.') -ForegroundColor Gray
    }
}
