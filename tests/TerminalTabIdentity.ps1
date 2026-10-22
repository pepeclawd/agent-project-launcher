# Regression check: launched tabs retain a unique identity for safe command delivery.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$launcherPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'AgentProjectLauncher.ps1'
$source = Get-Content -Raw -Encoding UTF8 $launcherPath
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($launcherPath,
    [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw 'Launcher has PowerShell parser errors.' }

if ($source -notmatch 'nt --title \"\{1\}\" --suppressApplicationTitle') {
    throw 'Windows Terminal is not suppressing application title replacement.'
}
if ($source -notmatch '\$preview\.WindowTitle = ''\{0\}  #\{1\}''') {
    throw 'Launched terminal titles do not carry a unique session marker.'
}
if ($source -notmatch 'LastRequestStatus') {
    throw 'Checkpoint failures do not retain the tab-agent result for diagnosis.'
}

Write-Output 'Terminal-tab identity regression check OK'
