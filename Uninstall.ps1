[CmdletBinding()]
param([switch]$KeepSettings)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$programRoot = Join-Path $env:LOCALAPPDATA 'Programs\AgentProjectLauncher'
$dataRoot = Join-Path $env:LOCALAPPDATA 'AgentProjectLauncher'
$startShortcut = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Agent Project Launcher.lnk'
$desktopShortcut = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)) 'Agent Project Launcher.lnk'

foreach ($shortcut in @($startShortcut, $desktopShortcut)) {
    if (Test-Path -LiteralPath $shortcut -PathType Leaf) { Remove-Item -LiteralPath $shortcut -Force }
}
if (Test-Path -LiteralPath $programRoot -PathType Container) {
    Remove-Item -LiteralPath $programRoot -Recurse -Force
}
if (-not $KeepSettings -and (Test-Path -LiteralPath $dataRoot -PathType Container)) {
    Remove-Item -LiteralPath $dataRoot -Recurse -Force
}

Write-Host 'Agent Project Launcher uninstalled.' -ForegroundColor Green
if ($KeepSettings) { Write-Host "Settings kept at $dataRoot" }

