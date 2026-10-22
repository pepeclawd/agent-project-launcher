# Regression checks: an offline share must not stop startup, and Live sessions
# must report the reasoning effort from the launch command.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$launcherPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'AgentProjectLauncher.ps1'
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($launcherPath,
    [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw 'Launcher has PowerShell parser errors.' }

foreach ($name in @('Test-ShareHostUp', 'Test-FolderReachable', 'Get-LiveLaunchDetails')) {
    $node = $ast.Find({ param($candidate)
        $candidate -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $candidate.Name -eq $name
    }, $true)
    if (-not $node) { throw "Missing launcher function $name" }
    Invoke-Expression $node.Extent.Text
}
$script:shareHostUp = @{}

# 192.0.2.0/24 is reserved for documentation and never answers.
$watch = [System.Diagnostics.Stopwatch]::StartNew()
if (Test-FolderReachable '\\192.0.2.1\Share\Project') { throw 'An offline share was reported as reachable.' }
if (Test-FolderReachable '\\192.0.2.1\Share\Other') { throw 'An offline share was reported as reachable.' }
if ($watch.Elapsed.TotalSeconds -gt 5) { throw 'Checking an offline share took too long: {0:0.0}s' -f $watch.Elapsed.TotalSeconds }
if (-not (Test-FolderReachable $env:SystemRoot)) { throw 'A local folder was reported as unreachable.' }
if (Test-FolderReachable '') { throw 'An empty path was reported as reachable.' }

$cases = @(
    @('Claude', 'claude.exe --model opus --effort xhigh', 'xhigh'),
    @('Claude', 'claude.exe "--effort" "high" --permission-mode plan', 'high'),
    @('Claude', 'claude.exe --model opus', ''),
    @('Codex', 'codex.exe -c model_reasoning_effort="medium" --model gpt-5.6-terra', 'medium'),
    @('Codex', 'codex.exe -c "model_reasoning_effort=\"low\""', 'low'),
    @('Codex', 'codex.exe --model gpt-5.6-terra', '')
)
foreach ($case in $cases) {
    $actual = (Get-LiveLaunchDetails -Agent $case[0] -CommandLine $case[1]).Effort
    if ($actual -ne $case[2]) { throw "Effort '$actual', expected '$($case[2])', for: $($case[1])" }
}

'OfflineShareAndEffort: OK'
