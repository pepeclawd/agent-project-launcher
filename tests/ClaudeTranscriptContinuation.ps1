# Regression check: a Claude process follows the transcript created by /clear.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$launcherPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'AgentProjectLauncher.ps1'
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($launcherPath,
    [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw 'Launcher has PowerShell parser errors.' }

foreach ($name in @('Test-ClaudeClearTranscriptStart', 'Get-ClaudeTranscriptContinuation')) {
    $node = $ast.Find({ param($candidate)
        $candidate -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $candidate.Name -eq $name
    }, $true)
    if (-not $node) { throw "Missing launcher function $name" }
    Invoke-Expression $node.Extent.Text
}

$folder = Join-Path ([System.IO.Path]::GetTempPath()) ('apl-transcript-' + [guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($folder)
try {
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $oldPath = Join-Path $folder 'old.jsonl'
    $clearPath = Join-Path $folder 'clear.jsonl'
    $unrelatedPath = Join-Path $folder 'unrelated.jsonl'
    [System.IO.File]::WriteAllText($oldPath, '{"type":"assistant","message":{"model":"claude-opus-5"}}', $utf8)
    [System.IO.File]::WriteAllText($clearPath, '{"type":"system","subtype":"local_command","commandRun":{"command":"clear","args":{}}}', $utf8)
    [System.IO.File]::WriteAllText($unrelatedPath, '{"type":"system","subtype":"local_command","commandRun":{"command":"clear","args":{}}}', $utf8)

    $old = Get-Item -LiteralPath $oldPath
    $clear = Get-Item -LiteralPath $clearPath
    $unrelated = Get-Item -LiteralPath $unrelatedPath
    $base = [datetime]::UtcNow.AddMinutes(-5)
    $old.CreationTimeUtc = $base
    $old.LastWriteTimeUtc = $base.AddMinutes(1)
    $clear.CreationTimeUtc = $base.AddMinutes(1)
    $clear.LastWriteTimeUtc = $base.AddMinutes(2)
    $unrelated.CreationTimeUtc = $base.AddMinutes(4)
    $unrelated.LastWriteTimeUtc = $base.AddMinutes(4)

    $actual = Get-ClaudeTranscriptContinuation -Transcript (Get-Item $oldPath) `
        -Files @((Get-Item $oldPath), (Get-Item $clearPath), (Get-Item $unrelatedPath))
    if ($actual.FullName -ne $clearPath) {
        throw 'The verified /clear continuation was not selected.'
    }
} finally {
    Get-ChildItem -LiteralPath $folder -File | Remove-Item -Force
    Remove-Item -LiteralPath $folder -Force
}

Write-Output 'Claude transcript continuation regression check OK'
