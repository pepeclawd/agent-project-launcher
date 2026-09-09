[CmdletBinding()]
param(
    [string]$ProjectRoot,
    [string]$NotesRoot,
    [string]$NotesProjectsRoot,
    [switch]$NoDesktopShortcut
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$documents = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)
if (-not $documents) { $documents = Join-Path $env:USERPROFILE 'Documents' }
if (-not $ProjectRoot) { $ProjectRoot = Join-Path $documents 'Projects' }
if (-not $NotesRoot) { $NotesRoot = Join-Path $documents 'Notes' }

$sourceRoot = $PSScriptRoot
$programRoot = Join-Path $env:LOCALAPPDATA 'Programs\AgentProjectLauncher'
$dataRoot = Join-Path $env:LOCALAPPDATA 'AgentProjectLauncher'
$startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
$desktop = [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)

foreach ($directory in @($programRoot, (Join-Path $programRoot 'icons'), $dataRoot, $startMenu, $ProjectRoot, $NotesRoot)) {
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $directory -Force)
    }
}

Copy-Item -LiteralPath (Join-Path $sourceRoot 'AgentProjectLauncher.ps1') -Destination $programRoot -Force
Copy-Item -LiteralPath (Join-Path $sourceRoot 'Uninstall.ps1') -Destination $programRoot -Force
Copy-Item -LiteralPath (Join-Path $sourceRoot 'icons\agent-launcher.ico') -Destination (Join-Path $programRoot 'icons') -Force

$configPath = Join-Path $dataRoot 'config.json'
$existing = $null
if (Test-Path -LiteralPath $configPath -PathType Leaf) {
    try { $existing = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json } catch { $existing = $null }
}
# Anything the installer is not asked about is carried over rather than reset:
# re-running it to pick up a new version should not quietly undo settings that
# were only ever entered by hand.
$keptNotesProjects = if ($NotesProjectsRoot) { [System.IO.Path]::GetFullPath($NotesProjectsRoot) }
                     elseif ($existing -and $existing.NotesProjectsRoot) { [string]$existing.NotesProjectsRoot }
                     else { '' }
$config = [ordered]@{
    ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
    NotesRoot   = [System.IO.Path]::GetFullPath($NotesRoot)
    NotesProjectsRoot = $keptNotesProjects
    ClaudePath = if ($existing -and $existing.ClaudePath) { [string]$existing.ClaudePath } else { '' }
    CodexPath  = if ($existing -and $existing.CodexPath) { [string]$existing.CodexPath } else { '' }
    ClaudeAccountLimits = [bool]($existing -and $existing.ClaudeAccountLimits)
}
$config | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8

$scriptPath = Join-Path $programRoot 'AgentProjectLauncher.ps1'
$iconPath = Join-Path $programRoot 'icons\agent-launcher.ico'
$shell = New-Object -ComObject WScript.Shell
function New-LauncherShortcut {
    param([Parameter(Mandatory)][string]$Path)
    $shortcut = $shell.CreateShortcut($Path)
    $shortcut.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $shortcut.Arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $scriptPath + '"'
    $shortcut.WorkingDirectory = $ProjectRoot
    $shortcut.IconLocation = $iconPath + ',0'
    $shortcut.Description = 'Start a Claude Code or OpenAI Codex session'
    $shortcut.Save()
}

New-LauncherShortcut (Join-Path $startMenu 'Agent Project Launcher.lnk')
if (-not $NoDesktopShortcut) { New-LauncherShortcut (Join-Path $desktop 'Agent Project Launcher.lnk') }

Write-Host ''
Write-Host 'Agent Project Launcher installed.' -ForegroundColor Green
Write-Host "Projects: $ProjectRoot"
Write-Host "Notes:    $NotesRoot"
Write-Host 'Open it from the Start menu or desktop shortcut.'
