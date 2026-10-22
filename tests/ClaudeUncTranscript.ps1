$ErrorActionPreference = 'Stop'

$launcherPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'AgentProjectLauncher.ps1'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $launcherPath,
    [ref]$tokens,
    [ref]$errors
)
if ($errors.Count -gt 0) { throw ($errors | Out-String) }

$functionAst = $ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'ConvertTo-ClaudeProjectKey'
}, $true) | Select-Object -First 1
if (-not $functionAst) { throw 'ConvertTo-ClaudeProjectKey was not found.' }
Invoke-Expression $functionAst.Extent.Text

$workspace = '\\100.88.113.28\H6_Shared\Projects\MP BOLAGEN CABLE TRAYS- COMPETITION OFFER SOFTWARE'
$expected = '--100-88-113-28-H6-Shared-Projects-MP-BOLAGEN-CABLE-TRAYS--COMPETITION-OFFER-SOFTWARE'
$actual = ConvertTo-ClaudeProjectKey $workspace
if ($actual -ne $expected) {
    throw "UNC transcript key mismatch. Expected '$expected'; got '$actual'."
}

Write-Output 'Claude UNC transcript key test passed.'
