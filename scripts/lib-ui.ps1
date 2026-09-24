<#
  lib-ui.ps1 - shared Chinese/English UI text loader for the RemoteOps agent
  launcher family (start-agent.ps1, watch-agent.ps1).

  Reads a sidecar "strings.<lang>.txt" (UTF-8, KEY=VALUE, '#' comment lines) from
  the working directory and exposes the texts through the T() function. The
  Chinese strings live in the .txt files because PowerShell 5.1 parses BOM-less
  .ps1 as GBK, and literal Chinese inside a .ps1 can corrupt the whole script.

  If the file is missing or empty, T() falls back to the ASCII English default
  baked into each call site, so this library can never break a launch.
#>

function Import-UiStrings {
    param(
        [string]$Dir  = '',
        [string]$Lang = 'zh'
    )
    $script:UiStrings = @{}
    if ($Dir -eq '') { return }
    $file = Join-Path $Dir ('strings.' + $Lang + '.txt')
    if (-not (Test-Path $file -PathType Leaf)) { return }
    try {
        $raw = [System.IO.File]::ReadAllLines($file, [System.Text.Encoding]::UTF8)
        foreach ($line in $raw) {
            $ln = $line.Trim()
            if ($ln -eq '' -or $ln.StartsWith('#')) { continue }
            $idx = $ln.IndexOf('=')
            if ($idx -le 0) { continue }
            $key   = $ln.Substring(0, $idx).Trim()
            $value = $ln.Substring($idx + 1).Trim()
            if ($key -ne '') { $script:UiStrings[$key] = $value }
        }
    } catch { $script:UiStrings = @{} }
}

function T {
    param([string]$Key = '', [string]$Fallback = '')
    if ($Key -ne '' -and $script:UiStrings.Count -gt 0 -and $script:UiStrings.ContainsKey($Key)) {
        return $script:UiStrings[$Key]
    }
    return $Fallback
}