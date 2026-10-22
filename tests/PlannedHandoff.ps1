# Scenario check for the scheduled handoff state machine. No CLI, UI or files are changed.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$launcherPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'AgentProjectLauncher.ps1'
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($launcherPath,
    [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw 'Launcher has PowerShell parser errors.' }

foreach ($name in @('Test-HandoffStatusEmpty', 'Test-HandoffStatusReady',
        'Get-HandoffUsagePercent', 'Process-PlannedHandoffs')) {
    $node = $ast.Find({ param($candidate)
        $candidate -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $candidate.Name -eq $name
    }, $true)
    if (-not $node) { throw "Missing launcher function $name" }
    Invoke-Expression $node.Extent.Text
}

$handoffHeadings = @('Goal', 'Done', 'In progress', 'Next steps',
    'Open questions and risks', 'Key files')
$script:plannedHandoffs = @{}
$script:processingPlannedHandoffs = $false
$script:claudeAccountUsage = $null
$script:claudeUsageEnabled = $false
$script:requests = 0
$script:starts = 0
$script:statusStamp = ''
$script:statusText = ''
$script:sourceVisible = $true
$script:sourceSession = [pscustomobject]@{
    AgentId = 123
    Agent = 'Codex'
    UsageMeasuredAt = Get-Date
    UsageDisplay = '84/12%'
}

function Get-LiveAgentSessions {
    if ($script:sourceVisible) { return @($script:sourceSession) }
    return @()
}
function Request-PlannedCheckpoint {
    param($Plan)
    $script:requests++
    $Plan.Requested = $true
    $Plan.RequestedAt = Get-Date
    return $true
}
function Get-HandoffStatusStamp { param($Path) return $script:statusStamp }
function Read-HandoffStatus { param($Path) return $script:statusText }
function Complete-PlannedHandoff {
    param($Plan, $StatusSource, $StatusText)
    $script:starts++
    [void]$script:plannedHandoffs.Remove([string]$Plan.Source.AgentId)
}
function Stop-PlannedHandoff { param($Key, $Reason) throw "Unexpected failure: $Reason" }

$plan = [pscustomobject]@{
    Source = [pscustomobject]@{ AgentId = 123; Agent = 'Codex'; Project = 'Test' }
    Timing = 'Automatic at 85% account use'
    Requested = $false
    RequestedAt = [datetime]::MinValue
    LastStatusStamp = ''
    MissingPolls = 0
    Handoff = [pscustomobject]@{ StatusPath = 'unused' }
}
$script:plannedHandoffs['123'] = $plan

Process-PlannedHandoffs
if ($script:requests -ne 0 -or $script:starts -ne 0) { throw 'Triggered below 85%.' }

$script:sourceVisible = $false
Process-PlannedHandoffs
if ($plan.MissingPolls -ne 1 -or $script:plannedHandoffs.Count -ne 1) {
    throw 'One transient process miss cancelled the plan.'
}

$script:sourceVisible = $true
$script:sourceSession.UsageDisplay = '85/12%'
Process-PlannedHandoffs
if ($script:requests -ne 1 -or $script:starts -ne 0) {
    throw 'The threshold did not request exactly one checkpoint.'
}

$script:statusStamp = 'file-v1'
$script:statusText = "### Goal`nOnly partial status"
Process-PlannedHandoffs
Process-PlannedHandoffs
if ($script:starts -ne 0) { throw 'Started on an incomplete status.' }

$script:statusStamp = 'file-v2'
$script:statusText = ($handoffHeadings | ForEach-Object {
    "### $_`nConcrete update"
}) -join "`n"
Process-PlannedHandoffs
Process-PlannedHandoffs
Process-PlannedHandoffs
if ($script:starts -ne 1 -or $script:plannedHandoffs.Count -ne 0) {
    throw 'A complete stable status did not start exactly one recipient.'
}

Write-Output 'Planned handoff scenario OK'
