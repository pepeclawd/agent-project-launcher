# Regression check for Codex process classification in Live sessions.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$launcherPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'AgentProjectLauncher.ps1'
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($launcherPath,
    [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw 'Launcher has PowerShell parser errors.' }

$node = $ast.Find({ param($candidate)
    $candidate -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $candidate.Name -eq 'Test-CodexTerminalCommandLine'
}, $true)
if (-not $node) { throw 'Missing launcher function Test-CodexTerminalCommandLine' }
Invoke-Expression $node.Extent.Text

$cases = @(
    @('codex.exe --sandbox workspace-write --ask-for-approval on-request --model gpt-5.6-terra', $true),
    @('codex.exe --approve-for-me --model gpt-5.6-sol', $true),
    @('codex.exe app-server', $false),
    @('codex.exe sandbox windows -- powershell.exe', $false)
)

foreach ($case in $cases) {
    $actual = Test-CodexTerminalCommandLine ([string]$case[0])
    if ($actual -ne [bool]$case[1]) {
        throw "Unexpected classification '$actual' for: $($case[0])"
    }
}

Write-Output 'Live-session Codex process filter OK'
