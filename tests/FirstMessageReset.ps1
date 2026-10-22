# Regression check: a successful ordinary launch consumes the first-message draft.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$launcherPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'AgentProjectLauncher.ps1'
$source = Get-Content -Raw -Encoding UTF8 $launcherPath
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($launcherPath,
    [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw 'Launcher has PowerShell parser errors.' }

$launchCall = $source.LastIndexOf('Start-AgentTerminal -SelectedAgent $agentName')
$clearCall = $source.IndexOf('$uiPrompt.Clear()', $launchCall)
$catchBlock = $source.IndexOf('} catch {', $launchCall)
if ($launchCall -lt 0 -or $clearCall -lt 0 -or $catchBlock -lt 0 -or $clearCall -gt $catchBlock) {
    throw 'The ordinary launch path does not clear the first-message box after a successful launch.'
}

Write-Output 'First-message reset regression check OK'
