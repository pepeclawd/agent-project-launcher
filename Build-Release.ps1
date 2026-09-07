[CmdletBinding()]
param([string]$Version = '1.0.0')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$source = $PSScriptRoot
# This script sits at the repository root, so the release drops into the repo's
# own ignored dist/ folder. Walking up from here put it two directories outside.
$dist = Join-Path $source 'dist'
$stage = Join-Path ([System.IO.Path]::GetTempPath()) ('AgentProjectLauncher-' + [guid]::NewGuid().ToString('N'))
$package = Join-Path $stage 'AgentProjectLauncher'
$zip = Join-Path $dist ("AgentProjectLauncher-$Version-Windows.zip")

try {
    [void](New-Item -ItemType Directory -Path $package -Force)
    [void](New-Item -ItemType Directory -Path (Join-Path $package 'icons') -Force)
    foreach ($name in @('AgentProjectLauncher.ps1', 'Install.ps1', 'Uninstall.ps1', 'README.md', 'LICENSE', 'CHANGELOG.md')) {
        Copy-Item -LiteralPath (Join-Path $source $name) -Destination $package -Force
    }
    Copy-Item -LiteralPath (Join-Path $source 'icons\agent-launcher.ico') -Destination (Join-Path $package 'icons') -Force
    if (-not (Test-Path -LiteralPath $dist -PathType Container)) { [void](New-Item -ItemType Directory -Path $dist -Force) }
    if (Test-Path -LiteralPath $zip -PathType Leaf) { Remove-Item -LiteralPath $zip -Force }
    Compress-Archive -LiteralPath $package -DestinationPath $zip -CompressionLevel Optimal
    Write-Host $zip
} finally {
    if (Test-Path -LiteralPath $stage -PathType Container) { Remove-Item -LiteralPath $stage -Recurse -Force }
}

