[CmdletBinding()]
param(
    [ValidateSet('Claude', 'Codex')][string]$Agent,
    [string]$Project,
    [string[]]$Context,
    [string]$Model,
    [ValidateSet('Read-only (plan)', 'Ask me', 'Accept edits', 'Auto-approve', 'Full access (no sandbox)')][string]$Mode,
    [ValidateSet('New session', 'Continue last', 'Pick a session')][string]$Start,
    [string]$Prompt,
    [string]$Effort,
    [string]$Persona,
    [ValidateSet('CLI default', 'Restricted', 'Allowed', 'No web tools')][string]$Web,
    [string]$HandoffFile,
    [ValidateSet('Ordinary', 'Orchestrator')][string]$SessionRole = 'Ordinary',
    [string]$OrchestratorAdapter,
    [ValidateSet('Terminal', 'Herdr')][string]$TerminalHost = 'Terminal',
    [string]$HerdrAdapter,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:launchTerminalHost = $TerminalHost

# Loaded before command-line mode as launch-preview helpers use these types too.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic
Add-Type -AssemblyName System.Net.Http

# WinForms has no built-in "vertical resize only" mode. Translate corner
# resize handles to top/bottom handles, disable the side handles, and repaint
# the whole client area while its height changes so old custom borders cannot
# remain as stripes.
try {
    Add-Type -TypeDefinition @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace Launcher {
    public static class AppIdentity {
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        private static extern int SetCurrentProcessExplicitAppUserModelID(string appID);
        public static int Set(string appID) {
            return SetCurrentProcessExplicitAppUserModelID(appID);
        }
    }

    // A ContextMenuStrip paints itself from ProfessionalColors, which stay
    // light whatever the control's own BackColor says. Supplying the table is
    // the only way to make a dropdown match the rest of the window.
    public class DarkMenuColors : ProfessionalColorTable {
        private readonly Color surface, edge, hover;
        public DarkMenuColors(Color surface, Color edge, Color hover) {
            this.surface = surface; this.edge = edge; this.hover = hover;
        }
        public override Color ToolStripDropDownBackground { get { return surface; } }
        public override Color MenuItemSelected { get { return hover; } }
        public override Color MenuItemSelectedGradientBegin { get { return hover; } }
        public override Color MenuItemSelectedGradientEnd { get { return hover; } }
        public override Color MenuItemBorder { get { return edge; } }
        public override Color MenuBorder { get { return edge; } }
        public override Color ImageMarginGradientBegin { get { return surface; } }
        public override Color ImageMarginGradientMiddle { get { return surface; } }
        public override Color ImageMarginGradientEnd { get { return surface; } }
        public override Color SeparatorDark { get { return edge; } }
        public override Color SeparatorLight { get { return edge; } }
    }

    public class VerticalResizeForm : Form {
        private const int WM_NCHITTEST = 0x0084;
        public VerticalResizeForm() {
            SetStyle(ControlStyles.AllPaintingInWmPaint |
                     ControlStyles.OptimizedDoubleBuffer |
                     ControlStyles.ResizeRedraw, true);
        }

        protected override void WndProc(ref Message m) {
            base.WndProc(ref m);
            if (m.Msg != WM_NCHITTEST) return;
        }
    }

    public class BufferedPanel : Panel {
        public bool BufferedRendering { get { return true; } }
        public BufferedPanel() {
            SetStyle(ControlStyles.AllPaintingInWmPaint |
                     ControlStyles.OptimizedDoubleBuffer |
                     ControlStyles.ResizeRedraw, true);
        }
    }

    // Windows refuses SetForegroundWindow to a process that does not already
    // own the foreground. Attaching to the current foreground thread's input
    // queue for the duration of the call is the documented way around it, and
    // it is what makes typing into another terminal land where it is aimed.
    public static class WindowFocus {
        [DllImport("user32.dll")] public static extern bool AllowSetForegroundWindow(uint dwProcessId);
        [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, IntPtr pid);
        [DllImport("user32.dll")] private static extern bool AttachThreadInput(uint attach, uint attachTo, bool doAttach);
        [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
        private const int SW_RESTORE = 9;

        public static bool Activate(IntPtr hWnd) {
            if (hWnd == IntPtr.Zero) return false;
            if (IsIconic(hWnd)) ShowWindow(hWnd, SW_RESTORE);
            uint self = GetCurrentThreadId();
            uint owner = GetWindowThreadProcessId(GetForegroundWindow(), IntPtr.Zero);
            bool attached = (owner != 0 && owner != self && AttachThreadInput(self, owner, true));
            try {
                SetForegroundWindow(hWnd);
            } finally {
                if (attached) AttachThreadInput(self, owner, false);
            }
            return GetForegroundWindow() == hWnd;
        }
    }
}
'@ -ReferencedAssemblies System.Windows.Forms,System.Drawing -ErrorAction Stop
} catch { }

# The tab walk runs in a helper process (see Invoke-TabAgent), so the launcher
# needs a copy of the interpreter to run it with.
$script:powerShellExe = Join-Path $PSHOME 'powershell.exe'
if (-not (Test-Path -LiteralPath $script:powerShellExe -PathType Leaf)) {
    $script:powerShellExe = 'powershell.exe'
}

$documentsRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)
if (-not $documentsRoot) { $documentsRoot = Join-Path $env:USERPROFILE 'Documents' }
# Config and settings are looked for beside the script first, so a checkout run
# where it sits keeps the whole tool - code, icons and personal paths - in one
# folder. %LOCALAPPDATA% is the fallback, and where Install.ps1 puts them for a
# copy installed under Programs. Both file names are in .gitignore, so nobody's
# paths travel with the repository.
$launcherDataRoot = Join-Path $env:LOCALAPPDATA 'AgentProjectLauncher'
function Get-LauncherDataPath {
    param([Parameter(Mandatory)][string]$FileName)
    $beside = Join-Path $PSScriptRoot $FileName
    if (Test-Path -LiteralPath $beside -PathType Leaf) { return $beside }
    return (Join-Path $launcherDataRoot $FileName)
}
$configPath = Get-LauncherDataPath 'config.json'
$publicConfig = $null
if (Test-Path -LiteralPath $configPath -PathType Leaf) {
    try { $publicConfig = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json } catch { $publicConfig = $null }
}
$codeProjectsRoot = if ($publicConfig -and $publicConfig.ProjectRoot) {
    [Environment]::ExpandEnvironmentVariables([string]$publicConfig.ProjectRoot)
} else { Join-Path $documentsRoot 'Projects' }
$vaultRoot = if ($publicConfig -and $publicConfig.NotesRoot) {
    [Environment]::ExpandEnvironmentVariables([string]$publicConfig.NotesRoot)
} else { Join-Path $documentsRoot 'Notes' }
# A vault usually keeps its projects in a subfolder rather than at its root.
# That subfolder is what the project list and the folder pickers open on, while
# the root above it stays what vault paths are shown relative to. Left unset the
# two are the same folder, which is the behaviour this replaces.
$projectsRoot = if ($publicConfig -and $publicConfig.NotesProjectsRoot) {
    [Environment]::ExpandEnvironmentVariables([string]$publicConfig.NotesProjectsRoot)
} else { $vaultRoot }
# Off unless a config asks for it. The check reads the local Claude credential
# file and calls an endpoint Anthropic does not document, so it is not something
# to switch on for someone by default - a released build behaves as it always
# has, and an install that wants the column opts in.
$script:claudeUsageEnabled = [bool]($publicConfig -and $publicConfig.ClaudeAccountLimits)
$claudePath = if ($publicConfig -and $publicConfig.ClaudePath) { [string]$publicConfig.ClaudePath } else { '' }
$codexPath = if ($publicConfig -and $publicConfig.CodexPath) { [string]$publicConfig.CodexPath } else { '' }
$settingsPath = Get-LauncherDataPath 'settings.json'
$script:sessionTitlesPath = Get-LauncherDataPath 'session-titles.json'
$script:sessionTitles = @{}
if (Test-Path -LiteralPath $script:sessionTitlesPath -PathType Leaf) {
    try {
        $savedTitles = Get-Content -LiteralPath $script:sessionTitlesPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($property in $savedTitles.PSObject.Properties) { $script:sessionTitles[$property.Name] = [string]$property.Value }
    } catch { $script:sessionTitles = @{} }
}
# Returns an empty string when saved, otherwise the reason it was not.
function Save-SessionTitles {
    try {
        $json = ConvertTo-Json -InputObject $script:sessionTitles -Depth 4
        [System.IO.File]::WriteAllText($script:sessionTitlesPath, $json, (New-Object System.Text.UTF8Encoding($false)))
        return ''
    } catch {
        return $_.Exception.Message
    }
}
# The vault is called whatever its folder is called - 'Notes' by default, and
# whatever NotesRoot points at otherwise. Naming it after the folder is what
# makes it recognisable in the list, and what lets it be typed as a shorthand
# on the command line.
$vaultName = Split-Path -Leaf $vaultRoot
if (-not $vaultName) { $vaultName = 'Notes' }
$script:claudeTranscriptByPid = @{}
$script:codexTranscriptByPid = @{}
$script:claudeAccountUsage = $null
$script:claudeUsageStatus = ''

# ---------------------------------------------------------------- helpers ---


function Test-SamePath {
    param([string]$Left, [string]$Right)
    if (-not $Left -or -not $Right) { return $false }
    return $Left.TrimEnd('\').Equals($Right.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)
}

# A folder on a share whose host is offline makes Test-Path throw "The network
# path was not found" rather than return false, which under Stop would take the
# whole launcher down. Unreachable counts as absent. An offline host also takes
# Windows 20-30 seconds per path to give up on, so a share's host gets a quick
# SMB port probe first and the answer is remembered for the rest of the run.
$script:shareHostUp = @{}
function Test-ShareHostUp {
    param([string]$HostName)
    if ($script:shareHostUp.ContainsKey($HostName)) { return $script:shareHostUp[$HostName] }
    $up = $false
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $connect = $client.BeginConnect($HostName, 445, $null, $null)
        if ($connect.AsyncWaitHandle.WaitOne(1500) -and $client.Connected) { $up = $true }
    } catch { $up = $false } finally { $client.Close() }
    $script:shareHostUp[$HostName] = $up
    return $up
}

function Test-FolderReachable {
    param([string]$Path)
    if (-not $Path) { return $false }
    if ($Path -match '^\\\\([^\\]+)\\' -and $Matches[1] -ne '?' -and $Matches[1] -ne '.') {
        if (-not (Test-ShareHostUp $Matches[1])) { return $false }
    }
    try { return [bool](Test-Path -LiteralPath $Path -PathType Container) } catch { return $false }
}

function Test-PathInList {
    param([string]$Path, [AllowEmptyCollection()][string[]]$List)
    foreach ($entry in $List) { if (Test-SamePath $entry $Path) { return $true } }
    return $false
}

function Read-SettingList {
    param($Settings, [string]$Name)
    $property = $Settings.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return @() }
    return @($property.Value | ForEach-Object { [string]$_ })
}

function Read-SettingText {
    param($Settings, [string]$Name)
    $property = $Settings.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return '' }
    return [string]$property.Value
}

function Get-LauncherSettings {
    $empty = [pscustomobject]@{
        HiddenProjects = @(); SavedProjects = @()
        LastAgent      = ''; LastProject   = ''; LastSessionRole = 'Ordinary'; LastTerminalHost = 'Terminal'
        ProjectContexts = @{}; AgentModels = @{}; AgentModes = @{}; ProjectModes = @{}; ProjectWeb = @{}
    }
    if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) { return $empty }
    try {
        $settings = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        return $empty
    }

    # Migrate the old name-based hide list. It hid a folder from BOTH the project
    # and the context list; hiding is path-based now, and projects only.
    $legacyHidden = @(Read-SettingList $settings 'hiddenProjects' | Where-Object { $_ -and -not $_.Contains('\') })
    $migrated = @(
        foreach ($name in $legacyHidden) {
            foreach ($root in @($codeProjectsRoot, $projectsRoot)) {
                $candidate = Join-Path $root $name
                if (Test-Path -LiteralPath $candidate -PathType Container) { (Resolve-Path -LiteralPath $candidate).ProviderPath }
            }
        }
    )
    $hiddenProjects = @(@(Read-SettingList $settings 'hiddenProjects' | Where-Object { $_ -and $_.Contains('\') }) + $migrated | Sort-Object -Unique)

    # Each project remembers its own context folders, keyed by project path.
    $projectContexts = @{}
    $stored = $settings.PSObject.Properties['projectContexts']
    if ($null -ne $stored -and $null -ne $stored.Value) {
        foreach ($entry in $stored.Value.PSObject.Properties) {
            $projectContexts[$entry.Name] = @($entry.Value | ForEach-Object { [string]$_ })
        }
    }

    # Each agent remembers its own model and permission mode.
    $agentModes = @{}
    $storedModes = $settings.PSObject.Properties['agentModes']
    if ($null -ne $storedModes -and $null -ne $storedModes.Value) {
        foreach ($entry in $storedModes.Value.PSObject.Properties) {
            $agentModes[$entry.Name] = [string]$entry.Value
        }
    }

    $agentModels = @{}
    $storedModels = $settings.PSObject.Properties['agentModels']
    if ($null -ne $storedModels -and $null -ne $storedModels.Value) {
        foreach ($entry in $storedModels.Value.PSObject.Properties) {
            $agentModels[$entry.Name] = [string]$entry.Value
        }
    }

    # A permission mode remembered per project outranks the per-agent one, so a
    # sensitive folder opens in Ask me even when the last session was on auto.
    $projectModes = @{}
    $storedProjectModes = $settings.PSObject.Properties['projectModes']
    if ($null -ne $storedProjectModes -and $null -ne $storedProjectModes.Value) {
        foreach ($entry in $storedProjectModes.Value.PSObject.Properties) {
            $projectModes[$entry.Name] = Get-ModeSlug ([string]$entry.Value)
        }
    }

    $projectWeb = @{}
    $storedProjectWeb = $settings.PSObject.Properties['projectWeb']
    if ($null -ne $storedProjectWeb -and $null -ne $storedProjectWeb.Value) {
        foreach ($entry in $storedProjectWeb.Value.PSObject.Properties) {
            $projectWeb[$entry.Name] = Get-WebSlug ([string]$entry.Value)
        }
    }

    return [pscustomobject]@{
        HiddenProjects  = $hiddenProjects
        SavedProjects   = @(Read-SettingList $settings 'savedProjects')
        LastAgent       = (Read-SettingText $settings 'lastAgent')
        LastProject     = (Read-SettingText $settings 'lastProject')
        LastSessionRole = (Read-SettingText $settings 'lastSessionRole')
        LastTerminalHost = (Read-SettingText $settings 'lastTerminalHost')
        ProjectContexts = $projectContexts
        AgentModels     = $agentModels
        AgentModes      = $agentModes
        ProjectModes    = $projectModes
        ProjectWeb      = $projectWeb
    }
}

function Save-LauncherSettings {
    $contextMap = [ordered]@{}
    foreach ($key in @($script:projectContexts.Keys | Sort-Object)) {
        $contextMap[$key] = @($script:projectContexts[$key])
    }
    $modelMap = [ordered]@{}
    foreach ($key in @($script:agentModels.Keys | Sort-Object)) {
        $modelMap[$key] = [string]$script:agentModels[$key]
    }
    $modeMap = [ordered]@{}
    foreach ($key in @($script:agentModes.Keys | Sort-Object)) {
        $modeMap[$key] = [string]$script:agentModes[$key]
    }
    $projectModeMap = [ordered]@{}
    foreach ($key in @($script:projectModes.Keys | Sort-Object)) {
        $projectModeMap[$key] = [string]$script:projectModes[$key]
    }
    $projectWebMap = [ordered]@{}
    foreach ($key in @($script:projectWeb.Keys | Sort-Object)) {
        $projectWebMap[$key] = [string]$script:projectWeb[$key]
    }
    # Settings are written back wherever they were read from.
    $settingsDirectory = Split-Path -Parent $settingsPath
    if ($settingsDirectory -and -not (Test-Path -LiteralPath $settingsDirectory -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $settingsDirectory -Force)
    }
    [ordered]@{
        hiddenProjects  = @($script:hiddenProjects | Sort-Object -Unique)
        savedProjects   = @($script:savedProjects  | Sort-Object -Unique)
        lastAgent       = [string]$script:lastAgent
        lastProject     = [string]$script:lastProject
        lastSessionRole = [string]$script:lastSessionRole
        lastTerminalHost = [string]$script:launchTerminalHost
        projectContexts = $contextMap
        projectModes    = $projectModeMap
        projectWeb      = $projectWebMap
        agentModels     = $modelMap
        agentModes      = $modeMap
    } | ConvertTo-Json -Depth 4 | ForEach-Object { [IO.File]::WriteAllText($settingsPath, $_, (New-Object Text.UTF8Encoding($false))) }
}

function Resolve-WorkspacePath {
    # A full path is taken as given, wherever it points - a second drive or a
    # UNC share is a legitimate place to work. The configured roots are only a
    # shorthand: a bare name is looked up inside them, and anything else has to
    # be spelled out in full.
    param([Parameter(Mandatory)][string]$Value, [switch]$AllowAnywhere)
    if ($Value -in @($vaultName, ($vaultName + ' (root)'))) { return $vaultRoot }
    if ($Value -eq '.') { return $codeProjectsRoot }
    if ([System.IO.Path]::IsPathRooted($Value)) {
        if (-not (Test-Path -LiteralPath $Value -PathType Container)) { throw "Folder '$Value' does not exist." }
        return (Resolve-Path -LiteralPath $Value).ProviderPath
    }
    foreach ($root in @($codeProjectsRoot, $projectsRoot)) {
        $candidate = Join-Path $root $Value
        if (Test-Path -LiteralPath $candidate -PathType Container) { return (Resolve-Path -LiteralPath $candidate).ProviderPath }
    }
    $found = @(
        foreach ($root in @($projectsRoot, $codeProjectsRoot)) {
            if (Test-Path -LiteralPath $root -PathType Container) {
                Get-ChildItem -LiteralPath $root -Directory -Recurse -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -eq $Value }
            }
        }
    )
    if ($found.Count -eq 1) { return $found[0].FullName }
    if ($found.Count -gt 1) { throw "More than one folder is named '$Value'. Pass a full path instead." }
    throw "Folder '$Value' was not found inside one of the configured roots."
}

$modelOtherLabel = 'Other...'

# A project says where its notes are in its own CLAUDE.md / AGENTS.md.
# Read that back and check it still resolves, so a stale link is visible before
# the session starts rather than silently sending the agent nowhere.
function Get-VaultLinks {
    param([string]$ProjectPath)
    $instructionFiles = @('CLAUDE.md', 'AGENTS.md')
    $present = @()
    $links = @()
    # Two ways a project names its notes. The first is the line this launcher
    # writes: the label 'Vault notes:' with a path after it. The second is how
    # projects wrote it before the launcher existed - any label at all, and a
    # path that simply begins at the vault folder's own name, so 'Datamodel:'
    # and 'Vision & planer:' count too. That name comes from the configured
    # root; nothing here assumes what the folder is called.
    $vaultLeaf = [regex]::Escape((Split-Path -Leaf $vaultRoot))
    foreach ($name in $instructionFiles) {
        $file = Join-Path $ProjectPath $name
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
        $present += $name
        $text = Get-Content -LiteralPath $file -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if (-not $text) { continue }
        $references = @()
        foreach ($match in [regex]::Matches($text, '(?im)^\s*(?:[-*]\s+)?(?:Vault notes|Notes):\s*`?([^`\r\n]+)`?\s*$')) {
            $references += $match.Groups[1].Value
        }
        foreach ($match in [regex]::Matches($text, '(?i)' + $vaultLeaf + '[\\/][A-Za-z0-9_\-\.\\/]+')) {
            $references += $match.Value
        }
        foreach ($raw in $references) {
            $reference = $raw.Trim().TrimEnd('.', '`', ')', ',', '/', '\')
            if (-not $reference) { continue }
            $full = [Environment]::ExpandEnvironmentVariables(($reference -replace '/', '\'))
            # A vault-relative reference starts with the vault folder's name and
            # an absolute one to the same place contains it, so cutting at that
            # name resolves both against the configured root - and a vault that
            # has since moved still lines up.
            if ($full -match ('(?i)^(?:.*\\)?' + $vaultLeaf + '$')) {
                $full = $vaultRoot
            } elseif ($full -match ('(?i)^(?:.*\\)?' + $vaultLeaf + '\\(.+)$')) {
                $full = Join-Path $vaultRoot $Matches[1]
            } elseif (-not [System.IO.Path]::IsPathRooted($full)) {
                $full = Join-Path $vaultRoot $full
            }
            if (Test-PathInList $full @($links | ForEach-Object { $_.Path })) { continue }
            $links += [pscustomobject]@{
                Reference = $reference
                Path      = $full
                Exists    = (Test-Path -LiteralPath $full)
            }
        }
    }
    return [pscustomobject]@{
        InstructionFiles = @($present)
        Links            = @($links)
    }
}

$effortDefaultLabel = 'Default'
$personaNoneLabel   = '(none)'

# Codex records which reasoning levels each model supports, so offer only the
# real ones for the model that is actually selected.
function Get-EffortChoices {
    param(
        [Parameter(Mandatory)][ValidateSet('Claude', 'Codex')][string]$Agent,
        [string]$Model
    )
    if ($Agent -eq 'Claude') {
        return @($effortDefaultLabel, 'low', 'medium', 'high', 'xhigh', 'max')
    }
    $levels = @()
    $cachePath = Join-Path $env:USERPROFILE '.codex\models_cache.json'
    if (Test-Path -LiteralPath $cachePath -PathType Leaf) {
        try {
            $cache = Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json
            $entry = @($cache.models | Where-Object { $_.slug -eq $Model }) | Select-Object -First 1
            if ($entry -and $entry.PSObject.Properties['supported_reasoning_levels']) {
                $levels = @($entry.supported_reasoning_levels | ForEach-Object { [string]$_.effort })
            }
        } catch { }
    }
    if ($levels.Count -eq 0) { $levels = @('low', 'medium', 'high') }
    return @($effortDefaultLabel) + $levels
}

function Get-OrchestratorContextPaths {
    param([string]$ProjectPath, [string[]]$Attached = @())
    $paths = @()
    $linked = Get-VaultLinks $ProjectPath
    foreach ($candidate in @($Attached) + @($linked.Links | Where-Object { $_.Exists } | ForEach-Object { $_.Path })) {
        if (-not $candidate -or (Test-SamePath $candidate $ProjectPath) -or (Test-SamePath $candidate $vaultRoot)) { continue }
        if (-not (Test-Path -LiteralPath $candidate)) { continue }
        if ((Test-Path -LiteralPath $candidate -PathType Leaf) -and [IO.Path]::GetExtension($candidate).ToLowerInvariant() -notin @('.md', '.pdf')) { continue }
        if (-not (Test-PathInList $candidate $paths)) { $paths += $candidate }
    }
    return $paths
}

function Get-EffortArguments {
    param(
        [Parameter(Mandatory)][ValidateSet('Claude', 'Codex')][string]$Agent,
        [string]$Effort
    )
    $value = ([string]$Effort).Trim()
    if (-not $value -or $value -eq $effortDefaultLabel) { return @() }
    if ($Agent -eq 'Claude') { return @('--effort', $value) }
    return @('-c', "model_reasoning_effort=`"$value`"")
}

# Subagent personas come from .claude/agents/*.md, project first then global.
function Get-PersonaChoices {
    param([string]$ProjectPath)
    $names = @()
    $roots = @()
    if ($ProjectPath) { $roots += (Join-Path $ProjectPath '.claude\agents') }
    $roots += (Join-Path $env:USERPROFILE '.claude\agents')
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        foreach ($file in (Get-ChildItem -LiteralPath $root -Filter '*.md' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
            $name = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
            if ($names -notcontains $name) { $names += $name }
        }
    }
    return @($personaNoneLabel) + $names
}

$startNewLabel = 'New session'
$startChoices  = @('New session', 'Continue last', 'Pick a session')

function Get-StartArguments {
    param(
        [Parameter(Mandatory)][ValidateSet('Claude', 'Codex')][string]$Agent,
        [string]$StartMode
    )
    $wanted = if ($StartMode -and ($startChoices -contains $StartMode)) { $StartMode } else { $startNewLabel }
    if ($Agent -eq 'Claude') {
        switch ($wanted) {
            'Continue last' { return @{ Leading = @(); Trailing = @('--continue') } }
            'Pick a session' { return @{ Leading = @(); Trailing = @('--resume') } }
            default { return @{ Leading = @(); Trailing = @() } }
        }
    }
    # Codex resumes through a subcommand, which has to come first.
    switch ($wanted) {
        'Continue last' { return @{ Leading = @('resume', '--last'); Trailing = @() } }
        'Pick a session' { return @{ Leading = @('resume'); Trailing = @() } }
        default { return @{ Leading = @(); Trailing = @() } }
    }
}

function Get-ModelSlug {
    param([string]$Value)
    $trimmed = ([string]$Value).Trim()
    # Tolerate labels written by older versions of this launcher.
    $trimmed = $trimmed -replace '\s*\(default\)$', ''
    if ($trimmed -match '^\s*Default\s*\((.+)\)\s*$') { return $Matches[1].Trim() }
    return $trimmed
}

# What each CLI would use on its own, so "Default" can say which model it means
# instead of being a mystery.
function Get-AgentDefaultModel {
    param([Parameter(Mandatory)][ValidateSet('Claude', 'Codex')][string]$Name)
    if ($Name -eq 'Claude') {
        $settingsFile = Join-Path $env:USERPROFILE '.claude\settings.json'
        if (Test-Path -LiteralPath $settingsFile -PathType Leaf) {
            try {
                $claudeSettings = Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json
                $modelProperty = $claudeSettings.PSObject.Properties['model']
                if ($null -ne $modelProperty -and $modelProperty.Value) { return [string]$modelProperty.Value }
            } catch { }
        }
        return ''
    }
    $configPath = Join-Path $env:USERPROFILE '.codex\config.toml'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { return '' }
    foreach ($line in (Get-Content -LiteralPath $configPath)) {
        if ($line -match '^\s*model\s*=\s*"([^"]+)"') { return $Matches[1] }
    }
    return ''
}

# Codex keeps the models it offers in a cache it refreshes itself, so read that
# rather than hard-coding a list that goes stale every release.
function Get-CodexModelSlugs {
    $cachePath = Join-Path $env:USERPROFILE '.codex\models_cache.json'
    if (-not (Test-Path -LiteralPath $cachePath -PathType Leaf)) { return @() }
    try {
        $cache = Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json
    } catch {
        return @()
    }
    if ($null -eq $cache.PSObject.Properties['models']) { return @() }
    return @(
        $cache.models |
            Where-Object { $_.visibility -eq 'list' } |
            Sort-Object priority |
            ForEach-Object { [string]$_.slug }
    )
}

# 'claude-opus-5' and the alias 'opus' reach the same model, and the alias keeps
# reaching it after the next release. Fold a pinned id back onto its alias so the
# list stays four names long.
function Get-ClaudeModelAlias {
    param([string]$Model)
    if ($Model -match '(?i)^claude-(opus|sonnet|haiku|fable)(?:-|$)') { return $Matches[1].ToLowerInvariant() }
    return $Model
}

function Get-ModelChoices {
    param([Parameter(Mandatory)][ValidateSet('Claude', 'Codex')][string]$Name)
    $configured = Get-AgentDefaultModel $Name
    if ($Name -eq 'Claude') {
        # Aliases only: each one follows the latest release of that model on its
        # own, so a version-pinned list would just go stale.
        $slugs = @('opus', 'sonnet', 'haiku', 'fable')
        $configured = Get-ClaudeModelAlias $configured
    } else {
        $slugs = @(Get-CodexModelSlugs)
    }
    # Whatever the CLI is configured to use belongs in the list even if it is a
    # pinned full name the presets do not cover.
    if ($configured -and -not ($slugs -contains $configured)) { $slugs = @($configured) + $slugs }
    return @($slugs)
}

function Get-AgentSpec {
    param([Parameter(Mandatory)][ValidateSet('Claude', 'Codex')][string]$Name)
    if ($Name -eq 'Claude') {
        $executable = $claudePath
        if (-not $executable -or -not (Test-Path -LiteralPath $executable -PathType Leaf)) {
            $command = Get-Command claude.exe, claude.cmd, claude -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($command) { $executable = if ($command.Path) { $command.Path } else { $command.Source } }
        }
        if (-not $executable) {
            $commonPath = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
            try { if (Test-Path -LiteralPath $commonPath -PathType Leaf) { $executable = $commonPath } } catch { }
        }
        if (-not $executable) { throw 'Claude CLI was not found. Install it or set ClaudePath in the launcher config.' }
        return [pscustomobject]@{ Name = 'Claude'; Executable = $executable }
    }
    $executable = $codexPath
    if (-not $executable -or -not (Test-Path -LiteralPath $executable -PathType Leaf)) {
        $command = Get-Command codex.cmd, codex.exe, codex -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command) { $executable = if ($command.Path) { $command.Path } else { $command.Source } }
    }
    if (-not $executable) {
        $commonPath = Join-Path $env:APPDATA 'npm\codex.cmd'
        try { if (Test-Path -LiteralPath $commonPath -PathType Leaf) { $executable = $commonPath } } catch { }
    }
    if (-not $executable) { throw 'Codex CLI was not found. Install it or set CodexPath in the launcher config.' }
    return [pscustomobject]@{ Name = 'Codex'; Executable = $executable }
}

# The two CLIs spell permissions differently; these are the equivalents.
# 'Auto-approve' is what the launcher always used to pass unconditionally.
# The order is deliberate: least power first, so the list reads as a dial.
$modeDefaultLabel = 'Auto-approve'
$modeChoices = @('Read-only (plan)', 'Ask me', 'Accept edits', 'Auto-approve', 'Full access (no sandbox)')

# 'Read-only' was the old label for the same thing; a settings file written
# before the rename must not silently fall back to Auto-approve.
function Get-ModeSlug {
    param([string]$Mode)
    if ($Mode -eq 'Read-only') { return 'Read-only (plan)' }
    return $Mode
}

function Get-ModeArguments {
    param(
        [Parameter(Mandatory)][ValidateSet('Claude', 'Codex')][string]$Agent,
        [string]$Mode
    )
    $wanted = Get-ModeSlug $Mode
    if (-not ($wanted -and ($modeChoices -contains $wanted))) { $wanted = $modeDefaultLabel }
    if ($Agent -eq 'Claude') {
        switch ($wanted) {
            'Read-only (plan)'         { return @('--permission-mode', 'plan') }
            'Ask me'                   { return @('--permission-mode', 'default') }
            'Accept edits'             { return @('--permission-mode', 'acceptEdits') }
            'Full access (no sandbox)' { return @('--permission-mode', 'bypassPermissions') }
            default                    { return @('--permission-mode', 'auto') }
        }
    }
    # Codex enforces these with its Windows restricted-token sandbox, so
    # 'Accept edits' is a real boundary there: no prompts, but writes outside
    # the workspace fail at the OS level rather than by the model's good manners.
    switch ($wanted) {
        'Read-only (plan)'         { return @('--sandbox', 'read-only') }
        'Ask me'                   { return @('--sandbox', 'workspace-write', '--ask-for-approval', 'on-request') }
        'Accept edits'             { return @('--sandbox', 'workspace-write', '--ask-for-approval', 'never') }
        'Full access (no sandbox)' { return @('--dangerously-bypass-approvals-and-sandbox') }
        default                    { return @('--approve-for-me') }
    }
}

# Internet access has two routes: a built-in web tool and network calls made by
# shell commands. Codex exposes controls for both routes. Claude only exposes a
# switch for its built-in web tools, so the UI says so instead of promising a
# network boundary the CLI cannot enforce.
$webDefaultLabel = 'CLI default'
$webChoices = @('CLI default', 'Restricted')

function Get-WebSlug {
    param([string]$Web)
    # Compatibility with labels written by the interrupted implementation.
    if ($Web -eq 'Allowed') { return 'CLI default' }
    if ($Web -eq 'No web tools') { return 'Restricted' }
    return $Web
}

function Get-WebArguments {
    param(
        [Parameter(Mandatory)][ValidateSet('Claude', 'Codex')][string]$Agent,
        [string]$Web
    )
    if ((Get-WebSlug $Web) -ne 'Restricted') { return @() }
    if ($Agent -eq 'Claude') { return @('--disallowed-tools', 'WebFetch', 'WebSearch') }
    # Web search is server-side and is separate from outbound traffic in the
    # command sandbox, so a restricted Codex session needs both settings.
    return @(
        '-c', 'web_search="disabled"',
        '-c', 'sandbox_workspace_write.network_access=false'
    )
}

# Takes exactly what it is given. No hidden fallbacks: an empty context list
# means no context.
function Get-VaultRelativeLabel {
    param([string]$Path)
    if (Test-SamePath $Path $vaultRoot) { return $vaultName + ' (root)' }
    if ($Path.StartsWith($vaultRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $vaultName + '\' + $Path.Substring($vaultRoot.Length).TrimStart('\')
    }
    return $Path
}
function Get-LaunchPreview {
    param(
        [Parameter(Mandatory)][string]$SelectedAgent,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [AllowEmptyCollection()][string[]]$ContextDirectories = @(),
        [string]$SelectedModel = '',
        [string]$SelectedMode = '',
        [string]$StartMode = '',
        [string]$OpeningPrompt = '',
        [string]$SelectedEffort = '',
        [string]$SelectedPersona = '',
        [string]$SelectedWeb = ''
    )
    if (-not $WorkingDirectory) { throw 'Choose a project folder.' }
    $workPath = (Resolve-Path -LiteralPath $WorkingDirectory).ProviderPath
    $contexts = @()
    foreach ($directory in $ContextDirectories) {
        if (-not $directory) { continue }
        $resolved = (Resolve-Path -LiteralPath $directory).ProviderPath
        if (Test-SamePath $resolved $workPath) { continue }
        if (-not (Test-PathInList $resolved $contexts)) { $contexts += $resolved }
    }
    # A share root has no leaf, so '\\host\share' would name the session nothing
    # at all and hand Claude an empty --name.
    $title = Split-Path -Leaf $workPath
    if (-not $title) { $title = $workPath.Trim('\').Replace('\', '-') }
    if (-not $title) { $title = 'workspace' }
    $spec  = Get-AgentSpec $SelectedAgent
    $model = Get-ModelSlug $SelectedModel
    $mode  = Get-ModeSlug $SelectedMode
    if (-not ($mode -and ($modeChoices -contains $mode))) { $mode = $modeDefaultLabel }
    $start = if ($StartMode -and ($startChoices -contains $StartMode)) { $StartMode } else { $startNewLabel }
    $startArgs = Get-StartArguments -Agent $spec.Name -StartMode $start

    $argumentList = @($startArgs.Leading)
    $argumentList += @(Get-ModeArguments -Agent $spec.Name -Mode $mode)
    if ($spec.Name -eq 'Claude') { $argumentList += @('--name', $title) }
    if ($model) { $argumentList += @('--model', $model) }
    $argumentList += @(Get-EffortArguments -Agent $spec.Name -Effort $SelectedEffort)
    $web = Get-WebSlug $SelectedWeb
    if (-not ($web -and ($webChoices -contains $web))) { $web = $webDefaultLabel }
    $argumentList += @(Get-WebArguments -Agent $spec.Name -Web $web)
    $persona = ([string]$SelectedPersona).Trim()
    # --agent is Claude-only; Codex has no equivalent flag.
    if ($persona -and $persona -ne $personaNoneLabel -and $spec.Name -eq 'Claude') {
        $argumentList += @('--agent', $persona)
    }
    foreach ($directory in $contexts) { $argumentList += @('--add-dir', $directory) }
    $argumentList += @($startArgs.Trailing)

    # A first message goes last, as the positional prompt. Codex's resume
    # subcommand takes [SESSION_ID] [PROMPT], so a bare prompt there would bind
    # to the session id instead - drop it rather than resume the wrong thing.
    $prompt = ([string]$OpeningPrompt).Trim()
    $promptDropped = $false
    if ($prompt -and $spec.Name -eq 'Codex' -and $startArgs.Leading.Count -gt 0) {
        $prompt = ''
        $promptDropped = $true
    }
    # Claude's --add-dir is declared <directories...>, so it keeps eating
    # arguments: a bare prompt after it becomes another directory and the
    # session opens with nothing typed, which is exactly what it looked like.
    # '--' ends option parsing. Codex's --add-dir takes a single <DIR>, so it
    # never had the problem.
    if ($prompt -and $spec.Name -eq 'Claude') { $argumentList += @('--') }
    if ($prompt) { $argumentList += @($prompt) }
    # The agent banner does not show attached directories, so put them in the
    # window title - it survives the TUI taking over the screen.
    $windowTitle = $title
    if ($contexts.Count -eq 1) {
        $windowTitle = '{0}  +  {1}' -f $title, (Get-VaultRelativeLabel $contexts[0])
    } elseif ($contexts.Count -gt 1) {
        $windowTitle = '{0}  +  {1} context folders' -f $title, $contexts.Count
    }
    # Claude supplies its own recognizable tab mark. Give Codex the compact
    # mark from its own header, and make the two agents distinguishable when
    # both are open in the same project.
    if ($spec.Name -eq 'Codex') { $windowTitle = '>_  ' + $windowTitle }
    return [pscustomobject]@{
        Agent              = $spec.Name
        Model              = if ($model) { $model } else { '(agent default)' }
        Mode               = $mode
        Effort             = $SelectedEffort
        Persona            = $SelectedPersona
        StartMode          = $start
        Web                = $web
        OpeningPrompt      = $prompt
        PromptDropped      = $promptDropped
        TerminalTitle      = $title
        WindowTitle        = $windowTitle
        WorkingDirectory   = $workPath
        ContextDirectories = $contexts
        Executable         = $spec.Executable
        Arguments          = $argumentList
    }
}

function Get-CompactModelName {
    param([string]$Model)
    if (-not $Model) { return '' }
    if ($Model -match '(?i)^claude-(opus|sonnet|haiku|fable)(?:-|$)') {
        return $Matches[1].ToLowerInvariant()
    }
    return $Model
}

function Format-ContextTokens {
    param([long]$Tokens, [long]$Window = 0)
    # Neither CLI writes a token count before the first turn. Calling that state
    # "waiting" distinguishes it from a failed lookup or an empty context.
    if ($Tokens -le 0) { return 'waiting' }
    $short = if ($Tokens -ge 1000000) { '{0:0.0}m' -f ($Tokens / 1000000) } else { '{0:0}k' -f ($Tokens / 1000) }
    if ($Window -gt 0) {
        $percent = [math]::Min(999, [math]::Round(($Tokens * 100.0) / $Window))
        return '{0} {1} {2}%' -f $short, [char]0x00B7, $percent
    }
    return $short
}

function Format-LimitResetTime {
    param([DateTimeOffset]$ResetAt)
    $localTime = $ResetAt.ToLocalTime().ToString('yyyy-MM-dd HH:mm zzz')
    if ($ResetAt -le [DateTimeOffset]::Now) {
        return ('last reported reset was {0} (passed; awaiting a new measurement)' -f $localTime)
    }
    return ('reset reported for {0}' -f $localTime)
}

function Get-ContextHealth {
    param([long]$Tokens, [long]$Window)
    if ($Tokens -le 0 -or $Window -le 0) { return [string][char]0x2014 }
    $percent = ($Tokens * 100.0) / $Window
    if ($percent -ge 80) { return 'Compact' }
    if ($percent -ge 60) { return 'Watch' }
    return 'OK'
}

function Get-LiveLaunchDetails {
    param([ValidateSet('Claude', 'Codex')][string]$Agent, [string]$CommandLine)

    $permission = 'Default'
    $effort = ''
    if ($Agent -eq 'Claude') {
        if ($CommandLine -match '(?i)--effort[''"]?\s+[''"]?([a-z]+)') { $effort = $Matches[1].ToLowerInvariant() }
    } elseif ($CommandLine -match '(?i)model_reasoning_effort\s*=\s*\\?[''"]?([a-z]+)') {
        $effort = $Matches[1].ToLowerInvariant()
    }
    if ($Agent -eq 'Claude') {
        if ($CommandLine -match '(?i)--permission-mode\s+(\S+)') {
            $permission = switch ($Matches[1].Trim('"', "'")) {
                'plan'              { 'Plan' }
                'manual'            { 'Ask' }
                'acceptEdits'       { 'Edits' }
                'auto'              { 'Auto' }
                'bypassPermissions' { 'Full' }
                default             { 'Default' }
            }
        }
    } else {
        if ($CommandLine -match '(?i)--dangerously-bypass-approvals-and-sandbox') { $permission = 'Full' }
        elseif ($CommandLine -match '(?i)--sandbox\s+read-only') { $permission = 'Plan' }
        elseif ($CommandLine -match '(?i)--ask-for-approval\s+on-request') { $permission = 'Ask' }
        elseif ($CommandLine -match '(?i)--ask-for-approval\s+never') { $permission = 'Edits' }
        elseif ($CommandLine -match '(?i)--approve-for-me') { $permission = 'Auto' }
    }

    return [pscustomobject]@{
        Permission = $permission
        Effort     = $effort
    }
}

function ConvertTo-ClaudeProjectKey {
    param([Parameter(Mandatory)][string]$Path)
    # Claude stores one transcript directory per workspace and replaces every
    # path character except letters, digits and existing hyphens. This
    # matters for UNC paths, where share names commonly contain underscores and
    # project names contain spaces.
    return $Path -replace '[^A-Za-z0-9-]', '-'
}

# The Codex executable is also used for non-interactive helper subcommands. A
# positional `sandbox` is one of those helpers; `--sandbox`, however, is the
# permission flag on a real terminal session and must remain visible.
function Test-CodexTerminalCommandLine {
    param([string]$CommandLine)
    return (($CommandLine -notmatch '(?i)\bapp-server\b') -and
            ($CommandLine -notmatch '(?i)(?:^|\s)sandbox(?:\s|$)'))
}

# /clear keeps the Claude process alive but starts a new transcript. Claude
# touches the old file while creating the replacement, and the replacement's
# opening metadata records the clear command. Following only that explicit
# link avoids confusing two independent sessions in the same workspace.
function Test-ClaudeClearTranscriptStart {
    param([Parameter(Mandatory)]$Transcript)
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($Transcript.FullName, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $bytesToRead = [int][math]::Min($stream.Length, 128KB)
        if ($bytesToRead -le 0) { return $false }
        $buffer = New-Object byte[] $bytesToRead
        $read = $stream.Read($buffer, 0, $bytesToRead)
        $prefix = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $read)
        return ($prefix -match '"type"\s*:\s*"system"' -and
                $prefix -match '"subtype"\s*:\s*"local_command"' -and
                $prefix -match '"commandRun"\s*:\s*\{[^{}]{0,512}"command"\s*:\s*"clear"')
    } catch {
        return $false
    } finally {
        if ($stream) { $stream.Dispose() }
    }
}

function Get-ClaudeTranscriptContinuation {
    param([Parameter(Mandatory)]$Transcript, [AllowEmptyCollection()][array]$Files = @())
    $current = $Transcript
    $visited = @{}
    while ($current -and -not $visited.ContainsKey($current.FullName)) {
        $visited[$current.FullName] = $true
        $next = $Files | Where-Object {
            $_.FullName -ne $current.FullName -and
            $_.CreationTimeUtc -gt $current.CreationTimeUtc -and
            [math]::Abs(($_.CreationTimeUtc - $current.LastWriteTimeUtc).TotalSeconds) -le 10 -and
            (Test-ClaudeClearTranscriptStart $_)
        } | Sort-Object CreationTimeUtc | Select-Object -First 1
        if (-not $next) { break }
        $current = $next
    }
    return $current
}

# Boil prompt text down to a one-line label for the Live sessions list: the
# first sentence of the first non-empty line, cut at a word boundary.
function ConvertTo-SessionTitle {
    param([AllowEmptyString()][string]$Text, [int]$MaxLength = 48, [int]$MinLength = 15)
    # Attachment placeholders such as "[Image #2]" or "[Pasted text #1 +40 lines]".
    $Text = [regex]::Replace([string]$Text, '\[(?:Image|Pasted text|Pasted image)[^\]]*\]', ' ')
    $line = @(([string]$Text -split '\r?\n') | ForEach-Object { $_.Trim() } | Where-Object { $_ }) | Select-Object -First 1
    if (-not $line) { return '' }
    # Text that opens with a quote mark is something pasted in from another
    # reply, not the user stating the task.
    if ($line -match ('^[''"`>' + [char]0x2018 + [char]0x201C + ']')) { return '' }
    $line = [string]$line -replace '^[#*\-\s]+', ''
    # A slash command or a short reply ("ok", "api error?") says nothing about
    # the work. Names and summaries pass a lower floor: "lint errors" is a title.
    if ($line.StartsWith('/') -or $line.Length -lt $MinLength) { return '' }
    $sentence = [regex]::Match($line, '^.{12,}?[.!?](?=\s|$)')
    if ($sentence.Success) { $line = $sentence.Value.TrimEnd('.') }
    if ($line.Length -gt $MaxLength) {
        $cut = $line.Substring(0, $MaxLength - 1)
        $space = $cut.LastIndexOf(' ')
        if ($space -ge 20) { $cut = $cut.Substring(0, $space) }
        $line = $cut.TrimEnd(' ', ',', ';', ':', '-') + [string][char]0x2026
    }
    return $line
}

function Get-TranscriptRecordField {
    param([string]$Record, [string]$Field)
    if (-not $Record -or $Record.Length -gt 65536) { return '' }
    try { return [string](($Record | ConvertFrom-Json -ErrorAction Stop).$Field) } catch { return '' }
}

# Codex names each thread in one index file shared by all sessions; the id is
# the tail of the rollout's file name.
$script:codexThreadNames = @{}
$script:codexThreadNamesStamp = ''
function Get-CodexThreadName {
    param([string]$ThreadId)
    if (-not $ThreadId) { return '' }
    $path = Join-Path $env:USERPROFILE '.codex\session_index.jsonl'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return '' }
    $item = Get-Item -LiteralPath $path
    $stamp = '{0}:{1}' -f $item.LastWriteTimeUtc.Ticks, $item.Length
    if ($script:codexThreadNamesStamp -ne $stamp) {
        $names = @{}
        $stream = $null
        $reader = $null
        try {
            $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
            # A thread can be renamed, so the last entry for an id wins.
            while ($null -ne ($line = $reader.ReadLine())) {
                if ($line -notmatch '"thread_name"') { continue }
                try {
                    $entry = $line | ConvertFrom-Json -ErrorAction Stop
                    if ($entry.id -and $entry.thread_name) { $names[[string]$entry.id] = [string]$entry.thread_name }
                } catch {
                }
            }
        } catch {
        } finally {
            if ($reader) { $reader.Dispose() }
            if ($stream) { $stream.Dispose() }
        }
        $script:codexThreadNames = $names
        $script:codexThreadNamesStamp = $stamp
    }
    if ($script:codexThreadNames.ContainsKey($ThreadId)) { return [string]$script:codexThreadNames[$ThreadId] }
    return ''
}

# Run one read-only Herdr CLI call and parse its JSON reply. The launcher UI
# thread waits on this, so a server that does not answer is abandoned quickly.
if (-not ('Launcher.ProcessEnvironment' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
namespace Launcher {
    public static class ProcessEnvironment {
        [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
        [DllImport("kernel32.dll")] static extern bool ReadProcessMemory(IntPtr process, IntPtr address, byte[] buffer, int size, out IntPtr read);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
        [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr process, int infoClass, byte[] info, int length, out int returned);

        // The NAME=value pairs of another process of the same user. Empty when
        // the process is gone, not readable, or not the same bitness.
        public static string[] Read(int pid) {
            if (IntPtr.Size != 8) return new string[0];
            IntPtr handle = OpenProcess(0x0410, false, pid);
            if (handle == IntPtr.Zero) return new string[0];
            try {
                byte[] basic = new byte[48]; int returned;
                if (NtQueryInformationProcess(handle, 0, basic, basic.Length, out returned) != 0) return new string[0];
                IntPtr peb = (IntPtr)BitConverter.ToInt64(basic, 8);
                byte[] word = new byte[8]; IntPtr read;
                if (!ReadProcessMemory(handle, (IntPtr)(peb.ToInt64() + 0x20), word, 8, out read)) return new string[0];
                long parameters = BitConverter.ToInt64(word, 0);
                if (!ReadProcessMemory(handle, (IntPtr)(parameters + 0x80), word, 8, out read)) return new string[0];
                long environment = BitConverter.ToInt64(word, 0);
                if (!ReadProcessMemory(handle, (IntPtr)(parameters + 0x3F0), word, 8, out read)) return new string[0];
                long size = BitConverter.ToInt64(word, 0);
                if (size <= 0 || size > 1048576) size = 65536;
                byte[] block = new byte[size];
                if (!ReadProcessMemory(handle, (IntPtr)environment, block, block.Length, out read)) return new string[0];
                string all = Encoding.Unicode.GetString(block, 0, (int)read.ToInt64());
                int end = all.IndexOf("\0\0", StringComparison.Ordinal);
                if (end >= 0) all = all.Substring(0, end);
                return all.Split('\0');
            } finally {
                CloseHandle(handle);
            }
        }
    }
}
'@
}

# A Herdr server started by the launcher's adapter runs in a private
# environment: XDG_CONFIG_HOME, XDG_STATE_HOME and HERDR_* point at its own
# folder, which is where its socket lives. Without them the CLI looks in the
# default place, finds nothing and every call fails. A launcher started from a
# shortcut has none of it, so it is read off the server process itself.
$script:herdrEnvironments = @{}
function Get-HerdrEnvKey {
    param($ServerRow, [string]$Session)
    if (-not $ServerRow) { return '' }
    $key = '{0}|{1}' -f $Session, [int]$ServerRow.ProcessId
    if (-not $script:herdrEnvironments.ContainsKey($key)) {
        $values = @{}
        try {
            foreach ($pair in @([Launcher.ProcessEnvironment]::Read([int]$ServerRow.ProcessId))) {
                $split = ([string]$pair).IndexOf('=')
                if ($split -gt 0) {
                    $name = ([string]$pair).Substring(0, $split)
                    if ($name -match '^(XDG_|HERDR_)') { $values[$name] = ([string]$pair).Substring($split + 1) }
                }
            }
        } catch {
        }
        $script:herdrEnvironments[$key] = $values
    }
    return $key
}

function Invoke-HerdrJson {
    # -AcceptEmpty is for commands that print nothing when they work (typing into
    # a pane); a clean exit then counts as an answer.
    param([string]$Exe, [string]$Session, [string[]]$Arguments, [string]$EnvKey = '', [switch]$AcceptEmpty)
    $argumentList = @()
    if ($Session) { $argumentList += @('--session', $Session) }
    $argumentList += $Arguments
    $process = $null
    try {
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $Exe
        $startInfo.Arguments = (@($argumentList | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' ')
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        if ($EnvKey -and $script:herdrEnvironments.ContainsKey($EnvKey)) {
            foreach ($name in @($script:herdrEnvironments[$EnvKey].Keys)) {
                $startInfo.EnvironmentVariables[[string]$name] = [string]$script:herdrEnvironments[$EnvKey][$name]
            }
        }
        $process = [System.Diagnostics.Process]::Start($startInfo)
        $output = $process.StandardOutput.ReadToEndAsync()
        $errors = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(3000)) {
            try { $process.Kill() } catch { }
            return $null
        }
        if ($AcceptEmpty -and -not ([string]$output.Result).Trim()) {
            if ($process.ExitCode -eq 0) { return [pscustomobject]@{ result = 'ok' } }
            return $null
        }
        return ($output.Result | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        return $null
    } finally {
        if ($process) { $process.Dispose() }
    }
}

# Herdr names tabs, not panes, so the tab is looked up from the pane first.
function Set-HerdrTabTitle {
    param([string]$Exe, [string]$Session, [string]$PaneId, [string]$Title, [string]$EnvKey = '')
    if (-not $Exe -or -not $PaneId -or -not $Title) { return $false }
    $pane = Invoke-HerdrJson -Exe $Exe -Session $Session -EnvKey $EnvKey -Arguments @('pane', 'get', $PaneId)
    if (-not $pane -or -not $pane.PSObject.Properties['result']) { return $false }
    $tabId = [string]$pane.result.pane.tab_id
    if (-not $tabId) { return $false }
    # Herdr has no end-of-options marker, so a leading dash would be read as an option.
    $label = ([string]$Title) -replace '^[-\s]+', ''
    if (-not $label) { return $false }
    $reply = Invoke-HerdrJson -Exe $Exe -Session $Session -EnvKey $EnvKey -Arguments @('tab', 'rename', $tabId, $label)
    return [bool]($reply -and $reply.PSObject.Properties['result'])
}

# The launcher's own shared Herdr session is the one server with a name on its
# command line; the private pilot servers have none.
function Get-LauncherHerdrServer {
    foreach ($row in @(Get-CimInstance Win32_Process -Filter "Name='herdr.exe'" -ErrorAction SilentlyContinue)) {
        if ([string]$row.CommandLine -match '(?i)--session\s+"?([^"\s]+)"?\s+server' -and $row.ExecutablePath) {
            $serverSession = $Matches[1]
            return [pscustomobject]@{ Exe = [string]$row.ExecutablePath; Session = $serverSession; EnvKey = (Get-HerdrEnvKey $row $serverSession) }
        }
    }
    return $null
}

# A title is put on a Herdr tab once per session. After that the tab is the
# user's to rename in Herdr without the launcher putting it back.
$script:herdrTitleApplied = @{}

# Herdr says what a pane runs only when asked, and tabs and panes can be
# renamed, moved and closed at any time. The picture is therefore taken afresh
# (at most every few seconds) and never remembered between refreshes, which is
# how a session moved to another tab would keep its old, now missing, tab.
$script:herdrSnapshots = @{}
function Get-HerdrSnapshot {
    param([string]$Exe, [string]$Session, [string]$EnvKey = '')
    if ($script:herdrSnapshots.ContainsKey($EnvKey)) {
        $existing = $script:herdrSnapshots[$EnvKey]
        if (((Get-Date) - $existing.At).TotalSeconds -lt 4) { return $existing }
    }
    $tabs = Invoke-HerdrJson -Exe $Exe -Session $Session -EnvKey $EnvKey -Arguments @('tab', 'list')
    if (-not $tabs) { return $null }
    $labels = @{}
    foreach ($tab in @($tabs.result.tabs)) { $labels[[string]$tab.tab_id] = [string]$tab.label }
    $panesByPid = @{}
    $agents = Invoke-HerdrJson -Exe $Exe -Session $Session -EnvKey $EnvKey -Arguments @('agent', 'list')
    if ($agents) {
        foreach ($pane in @($agents.result.agents)) {
            $info = Invoke-HerdrJson -Exe $Exe -Session $Session -EnvKey $EnvKey -Arguments @('pane', 'process-info', '--pane', [string]$pane.pane_id)
            if (-not $info) { continue }
            $entry = [pscustomobject]@{ TabId = [string]$pane.tab_id; PaneId = [string]$pane.pane_id }
            $processInfo = $info.result.process_info
            $ids = @(@($processInfo.foreground_processes) | ForEach-Object { [int]$_.pid })
            # The pane's own shell sits above whatever runs in it, so it finds
            # the pane even while the agent has a tool process in front.
            if ($processInfo.PSObject.Properties['shell_pid'] -and $processInfo.shell_pid) { $ids += [int]$processInfo.shell_pid }
            foreach ($id in $ids) { $panesByPid[$id] = $entry }
        }
    }
    $snapshot = [pscustomobject]@{ At = Get-Date; Labels = $labels; PanesByPid = $panesByPid }
    $script:herdrSnapshots[$EnvKey] = $snapshot
    return $snapshot
}

function Get-HerdrPaneInfo {
    # Herdr names the pane's foreground process, which for Codex is the cmd.exe
    # shim above node and codex.exe, so every process from the agent up to the
    # pane's shell is a candidate.
    param($HerdrRow, [int[]]$ProcessIds)
    $none = [pscustomobject]@{ Exe = ''; Session = ''; EnvKey = ''; PaneId = ''; TabTitle = '' }
    try {
        $exe = [string]$HerdrRow.ExecutablePath
        if (-not $exe -or -not (Test-Path -LiteralPath $exe -PathType Leaf)) { return $none }
        $session = ''
        if ([string]$HerdrRow.CommandLine -match '(?i)--session\s+"?([^"\s]+)') { $session = $Matches[1] }
        $envKey = Get-HerdrEnvKey $HerdrRow $session
        $snapshot = Get-HerdrSnapshot -Exe $exe -Session $session -EnvKey $envKey
        if (-not $snapshot) { return $none }
        $known = $null
        foreach ($candidateId in $ProcessIds) {
            if ($snapshot.PanesByPid.ContainsKey([int]$candidateId)) { $known = $snapshot.PanesByPid[[int]$candidateId]; break }
        }
        if (-not $known) { return $none }
        # Whatever the tab is called in Herdr is the title, even a bare
        # number: it is what the user sees there, so nothing is invented.
        $tabTitle = ''
        if ($snapshot.Labels.ContainsKey($known.TabId)) {
            $tabTitle = ([string]$snapshot.Labels[$known.TabId]).Trim()
            if ($tabTitle.Length -gt 80) { $tabTitle = $tabTitle.Substring(0, 80).TrimEnd() }
        }
        return [pscustomobject]@{ Exe = $exe; Session = $session; EnvKey = $envKey; PaneId = $known.PaneId; TabTitle = $tabTitle }
    } catch {
    }
    return $none
}

# Herdr runs every session inside one Windows Terminal tab, so there is no tab
# per session to select. Herdr is asked to focus the session's pane, then the
# terminal window that hosts Herdr is brought to the front.
function Invoke-HerdrGoTo {
    param([Parameter(Mandatory)]$Session)
    # No pane means the session sits in a Herdr server the launcher cannot talk to.
    if (-not $Session.HerdrPane -or -not $Session.HerdrExe) { return 'privateherdr' }
    $reply = Invoke-HerdrJson -Exe $Session.HerdrExe -Session $Session.HerdrSession -EnvKey $Session.HerdrEnvKey -Arguments @('agent', 'focus', [string]$Session.HerdrPane)
    if (-not $reply -or -not $reply.PSObject.Properties['result']) { return 'notfound' }
    # The outer tab is titled Herdr, whatever it is showing inside.
    $outer = [pscustomobject]@{ WindowTitle = 'Herdr'; Project = 'Herdr'; Agent = 'Claude' }
    return (Invoke-TabAgent -Session $outer)
}

# Claude registers every live process in ~/.claude/sessions/<pid>.json with its
# session id and working folder. That is exact where the launcher otherwise has
# to guess from timestamps and names, and it covers sessions the launcher did
# not start, such as a `claude` typed by hand in a Herdr pane.
function Get-ClaudeSessionRecord {
    param([int]$ProcessId, [datetime]$Started)
    $path = Join-Path $env:USERPROFILE ('.claude\sessions\{0}.json' -f $ProcessId)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try {
        $record = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        # A reused pid would leave another process's record behind.
        if ($record.PSObject.Properties['procStart'] -and $record.procStart) {
            $recordStart = [datetime]::FromFileTime([long]$record.procStart)
            if ([math]::Abs(($recordStart - $Started).TotalSeconds) -gt 5) { return $null }
        }
        return [pscustomobject]@{
            SessionId = if ($record.PSObject.Properties['sessionId']) { [string]$record.sessionId } else { '' }
            Cwd       = if ($record.PSObject.Properties['cwd']) { [string]$record.cwd } else { '' }
        }
    } catch {
        return $null
    }
}

# A session started outside the launcher has no workspace marker, so its
# transcript folder is unknown. Claude writes the --name value as the first
# records of the transcript, which identifies the file across all projects.
function Find-ExternalClaudeTranscript {
    param([string]$CommandLine, [datetime]$Started)
    $nameMatch = [regex]::Match($CommandLine, '(?:^|\s)(?:--name|-n)\s+(?:"([^"]+)"|''([^'']+)''|(\S+))')
    if (-not $nameMatch.Success) { return $null }
    $name = ($nameMatch.Groups[1].Value, $nameMatch.Groups[2].Value, $nameMatch.Groups[3].Value |
        Where-Object { $_ } | Select-Object -First 1)
    $claimed = @($script:claudeTranscriptByPid.Values)
    $root = Join-Path $env:USERPROFILE '.claude\projects'
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return $null }
    $candidates = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -File -Filter '*.jsonl' -ErrorAction SilentlyContinue } |
        Where-Object { $_.CreationTime -ge $Started.AddSeconds(-5) -and $claimed -notcontains $_.FullName } |
        Sort-Object CreationTime)
    foreach ($candidate in $candidates) {
        $stream = $null
        try {
            $stream = [System.IO.File]::Open($candidate.FullName, [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $buffer = New-Object byte[] ([int][math]::Min($stream.Length, 4KB))
            $read = $stream.Read($buffer, 0, $buffer.Length)
            $head = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $read)
            $titleMatch = [regex]::Match($head, '"customTitle"\s*:\s*"((?:[^"\\]|\\.)*)"')
            if ($titleMatch.Success -and $titleMatch.Groups[1].Value -ceq $name) { return $candidate }
        } catch {
        } finally {
            if ($stream) { $stream.Dispose() }
        }
    }
    return $null
}

function Get-ClaudeTranscriptModel {
    param(
        [string]$Workspace,
        [string]$Project,
        [datetime]$Started,
        [string]$CommandLine,
        [int]$ProcessId,
        [string]$RegisteredSessionId = ''
    )

    # Claude changes /model inside the running process, so its command line
    # only tells us the launch model. The transcript records the model on each
    # assistant entry. Read only those metadata fields, never message content.
    $workspacePath = $Workspace
    if (-not $workspacePath -and $Project -and $Project -ne '(external)') {
        if ($Project -eq $vaultName) {
            $workspacePath = $vaultRoot
        } else {
            foreach ($root in @($codeProjectsRoot, $projectsRoot)) {
                $candidate = Join-Path $root $Project
                if (Test-Path -LiteralPath $candidate -PathType Container) {
                    $workspacePath = (Resolve-Path -LiteralPath $candidate).ProviderPath
                    break
                }
            }
        }
    }
    $transcript = $null
    $certain = $false
    $pidKey = [string]$ProcessId
    if ($script:claudeTranscriptByPid.ContainsKey($pidKey)) {
        $remembered = [string]$script:claudeTranscriptByPid[$pidKey]
        if (Test-Path -LiteralPath $remembered -PathType Leaf) {
            $transcript = Get-Item -LiteralPath $remembered
        }
    }

    if ($workspacePath) {
        $projectKey = ConvertTo-ClaudeProjectKey $workspacePath
        $transcriptDirectory = Join-Path (Join-Path $env:USERPROFILE '.claude\projects') $projectKey
    } else {
        if (-not $transcript) {
            $transcript = Find-ExternalClaudeTranscript -CommandLine $CommandLine -Started $Started
            if ($transcript) { $certain = $true }
        }
        if (-not $transcript) { return $null }
        $transcriptDirectory = $transcript.DirectoryName
    }
    if (-not (Test-Path -LiteralPath $transcriptDirectory -PathType Container)) { return $null }

    $files = @(Get-ChildItem -LiteralPath $transcriptDirectory -File -Filter '*.jsonl' -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) { return $null }

    if (-not $transcript) {
        # An explicit resume exposes the session id. A new session writes its
        # transcript once the first message is sent, so the file this process
        # created is the one that appeared at or after it started.
        $sessionId = ''
        if ($CommandLine -match '(?i)\b([0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12})\b') { $sessionId = $Matches[1] }
        # The registry names the session the process is on now, which a
        # --resume id in the command line may no longer be.
        if ($RegisteredSessionId) { $sessionId = $RegisteredSessionId }
        if ($sessionId) {
            $transcript = $files | Where-Object { $_.BaseName -eq $sessionId } | Select-Object -First 1
            if ($transcript) { $certain = $true }
        }
        if (-not $transcript) {
            # Only forward in time: a file created before this process belongs to
            # some earlier session, however close the timestamps happen to be.
            $ownFiles = @($files | Where-Object { $_.CreationTime -ge $Started.AddSeconds(-5) } |
                Sort-Object CreationTime)
            if ($ownFiles.Count -gt 0) { $transcript = $ownFiles[0]; $certain = $true }
        }
        if (-not $transcript) {
            # '--continue' reopens an older transcript and keeps writing to it.
            $transcript = $files | Where-Object { $_.LastWriteTime -ge $Started.AddMinutes(-5) } |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
        }
        if (-not $transcript) { return $null }
    }

    # A long-lived process can cross one or more /clear boundaries. Advance
    # from the originally matched file through only verified successors.
    $transcript = Get-ClaudeTranscriptContinuation -Transcript $transcript -Files $files
    # A guess is remembered only until the next refresh. Caching it would pin a
    # session that had not written its transcript yet to whichever file happened
    # to be newest when the list was first opened.
    if ($certain -or $script:claudeTranscriptByPid.ContainsKey($pidKey)) {
        $script:claudeTranscriptByPid[$pidKey] = $transcript.FullName
    }

    # Transcript lines can contain multi-megabyte tool results. Get-Content
    # -Tail plus ConvertFrom-Json loads all of that onto the UI thread and can
    # make WinForms appear hung. Read a bounded byte window from the end and
    # inspect only the small metadata prefix of complete JSONL records.
    $activeModel = ''
    $activeEffort = ''
    [long]$contextTokens = 0
    $usageDisplay = [string][char]0x2014
    $usageDetail = 'Run /usage in this Claude session, then Refresh, to update limit usage.'
    $usageMeasuredAt = [datetime]::MinValue
    $pendingLocalCommand = ''
    $customTitleRecord = ''
    $aiTitleRecord = ''
    $promptRecords = New-Object System.Collections.Generic.List[string]
    $lastPromptText = $null
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($transcript.FullName, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $bytesToRead = [int][math]::Min($stream.Length, 4MB)
        if ($bytesToRead -gt 0) {
            [void]$stream.Seek(-$bytesToRead, [System.IO.SeekOrigin]::End)
            $buffer = New-Object byte[] $bytesToRead
            $read = $stream.Read($buffer, 0, $bytesToRead)
            $tailText = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $read)
            $lines = @($tailText -split "`n")
            # The first item is complete only when the whole file fit.
            $firstLine = if ($bytesToRead -eq $stream.Length) { 0 } else { 1 }
            for ($index = $firstLine; $index -lt $lines.Count; $index++) {
                $record = $lines[$index]
                $prefix = $record
                if ($prefix.Length -gt 4096) { $prefix = $prefix.Substring(0, 4096) }
                # Title records are small and start with their type. Keep the
                # newest of each; a few prompts back, in case the latest one
                # is only "ok".
                if ($prefix.StartsWith('{"type":"last-prompt"', [System.StringComparison]::Ordinal)) {
                    # Claude rewrites the same prompt on every turn; only a
                    # change in text takes a slot in the window.
                    $promptText = [regex]::Match($prefix, '"lastPrompt"\s*:\s*"((?:[^"\\]|\\.)*)"').Groups[1].Value
                    if ($promptText -ne $lastPromptText) {
                        $lastPromptText = $promptText
                        if ($promptRecords.Count -ge 8) { $promptRecords.RemoveAt(0) }
                        $promptRecords.Add($record)
                    }
                    continue
                }
                if ($prefix.StartsWith('{"type":"custom-title"', [System.StringComparison]::Ordinal)) { $customTitleRecord = $record; continue }
                if ($prefix.StartsWith('{"type":"ai-title"', [System.StringComparison]::Ordinal)) { $aiTitleRecord = $record; continue }
                # The record's own '"type":"assistant"' is written after the
                # message content, so on any turn longer than the prefix it is
                # out of reach. The message header is not: role and model sit in
                # the first few hundred bytes. Subagent turns carry their own
                # context and must not be mistaken for the session's.
                if ($prefix -match '"role"\s*:\s*"assistant"' -and
                    $prefix -notmatch '"isSidechain"\s*:\s*true' -and
                    $prefix -match '"model"\s*:\s*"(claude-[^"\\]+)"') {
                    $activeModel = $Matches[1]
                    # The session's effort sits in the record's trailing metadata,
                    # after the message. Quotes inside message text are escaped,
                    # so this exact key can only be the real field.
                    $effortStart = $record.LastIndexOf('"effort":"', [System.StringComparison]::Ordinal)
                    if ($effortStart -ge 0) {
                        $effortMatch = [regex]::Match($record.Substring($effortStart), '^"effort":"([a-z]+)"')
                        if ($effortMatch.Success) { $activeEffort = $effortMatch.Groups[1].Value }
                    }
                    $usageStart = $record.LastIndexOf('"usage":', [System.StringComparison]::Ordinal)
                    if ($usageStart -ge 0) {
                        $usageText = $record.Substring($usageStart)
                        [long]$total = 0
                        foreach ($field in @('input_tokens', 'cache_creation_input_tokens', 'cache_read_input_tokens', 'output_tokens')) {
                            $tokenMatch = [regex]::Match($usageText,
                                '"' + $field + '"\s*:\s*(\d+)')
                            if ($tokenMatch.Success) { $total += [long]$tokenMatch.Groups[1].Value }
                        }
                        if ($total -gt 0) { $contextTokens = $total }
                    }
                }
                if ($prefix -match '"type"\s*:\s*"system"' -and
                    $prefix -match '"subtype"\s*:\s*"local_command"') {
                    $commandMatch = [regex]::Match($record, '<command-name>(/[^<]+)</command-name>')
                    if ($commandMatch.Success) { $pendingLocalCommand = $commandMatch.Groups[1].Value }
                    if ($record -match '<local-command-stdout>') {
                        if ($record -match 'Context Usage') {
                            # /context is written immediately and includes the
                            # model selected by /model before it has replied.
                            $contextModel = [regex]::Match($record, 'claude-(?:opus|sonnet|haiku|fable)-[A-Za-z0-9.\-]+')
                            if ($contextModel.Success) { $activeModel = $contextModel.Value }
                        }
                        if ($pendingLocalCommand -eq '/usage') {
                            try {
                                $usageEntry = $record | ConvertFrom-Json -ErrorAction Stop
                                $usageText = [string]$usageEntry.content
                                $percentages = @([regex]::Matches($usageText, '(\d+(?:\.\d+)?)%') |
                                    ForEach-Object { $_.Groups[1].Value + '%' })
                                if ($percentages.Count -gt 0) {
                                    $usageDisplay = ($percentages | Select-Object -First 2) -join '/'
                                    $usageDetail = 'Claude /usage: ' + $usageDisplay
                                    $usageMeasuredAt = [datetime]$usageEntry.timestamp
                                }
                            } catch {
                            }
                        }
                        $pendingLocalCommand = ''
                    }
                }
            }
        }
    } catch {
        return $null
    } finally {
        if ($stream) { $stream.Dispose() }
    }
    if (-not $activeModel) { return $null }

    # A launcher session is started with --name set to its project, which
    # says nothing about the work and also stops Claude from writing an
    # ai-title. A name that differs from the project (/rename, or an external
    # --name) is a deliberate label and wins. Otherwise fall back to the
    # newest prompt that says something.
    $autoTitle = ''
    $titleSource = ''
    $customTitle = ConvertTo-SessionTitle (Get-TranscriptRecordField $customTitleRecord 'customTitle') 60 3
    if ($customTitle -and $customTitle -ne $Project) {
        $autoTitle = $customTitle
        $titleSource = 'the session name'
    }
    if (-not $autoTitle) {
        $autoTitle = ConvertTo-SessionTitle (Get-TranscriptRecordField $aiTitleRecord 'aiTitle') 60 3
        if ($autoTitle) { $titleSource = 'Claude''s own summary of the session' }
    }
    if (-not $autoTitle) {
        for ($i = $promptRecords.Count - 1; $i -ge 0 -and -not $autoTitle; $i--) {
            $autoTitle = ConvertTo-SessionTitle (Get-TranscriptRecordField $promptRecords[$i] 'lastPrompt')
        }
        if ($autoTitle) { $titleSource = 'the latest prompt' }
    }

    # Claude 5's CLI context window is one million tokens. The transcript's
    # usage total is the same pre-compaction token count shown by /context.
    [long]$contextWindow = 1000000
    return [pscustomobject]@{
        Display = Get-CompactModelName $activeModel
        Exact   = $activeModel
        Title   = $autoTitle
        TitleSource = $titleSource
        Effort  = $activeEffort
        ContextTokens = $contextTokens
        ContextWindow = $contextWindow
        UsageDisplay = $usageDisplay
        UsageDetail  = $usageDetail
        UsageMeasuredAt = $usageMeasuredAt
    }
}

function Get-ClaudeAccountUsage {
    if (-not $script:claudeUsageEnabled) { return $null }
    # This is the same read-only OAuth endpoint used by Claude's /usage.
    # Keep the access token local to this function and never return/log errors
    # that could contain request headers.
    $accessToken = $null
    $headers = $null
    $credentials = $null
    $client = $null
    $request = $null
    $response = $null
    $script:claudeUsageStatus = ''
    try {
        $credentialPath = Join-Path $env:USERPROFILE '.claude\.credentials.json'
        if (-not (Test-Path -LiteralPath $credentialPath -PathType Leaf)) { return $null }
        $credentials = Get-Content -LiteralPath $credentialPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $accessToken = [string]$credentials.claudeAiOauth.accessToken
        if (-not $accessToken) { return $null }
        $client = New-Object System.Net.Http.HttpClient
        $client.Timeout = [TimeSpan]::FromSeconds(5)
        $request = New-Object System.Net.Http.HttpRequestMessage(
            [System.Net.Http.HttpMethod]::Get,
            'https://api.anthropic.com/api/oauth/usage'
        )
        $request.Headers.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $accessToken)
        [void]$request.Headers.TryAddWithoutValidation('anthropic-beta', 'oauth-2025-04-20')
        $task = $client.SendAsync($request)
        while (-not $task.IsCompleted) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 25
        }
        $response = $task.GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) {
            $script:claudeUsageStatus = if ([int]$response.StatusCode -eq 429) {
                'Anthropic rate-limited the usage check. Click Refresh again later.'
            } else {
                'Anthropic usage check failed with HTTP {0}.' -f [int]$response.StatusCode
            }
            return $null
        }
        $json = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $usage = $json | ConvertFrom-Json -ErrorAction Stop
        if (-not $usage.five_hour -or -not $usage.seven_day) { return $null }

        $fiveHour = [double]$usage.five_hour.utilization
        $sevenDay = [double]$usage.seven_day.utilization
        $fiveReset = Format-LimitResetTime ([DateTimeOffset]::Parse([string]$usage.five_hour.resets_at))
        $sevenReset = Format-LimitResetTime ([DateTimeOffset]::Parse([string]$usage.seven_day.resets_at))
        return [pscustomobject]@{
            Display = '{0:0}/{1:0}%' -f $fiveHour, $sevenDay
            Detail  = @(
                ('5h window: {0:0}% used; {1}' -f $fiveHour, $fiveReset),
                ('7d window: {0:0}% used; {1}' -f $sevenDay, $sevenReset)
            ) -join "`r`n"
            MeasuredAt = Get-Date
        }
    } catch {
        if (-not $script:claudeUsageStatus) { $script:claudeUsageStatus = 'Claude usage could not be refreshed.' }
        return $null
    } finally {
        if ($response) { $response.Dispose() }
        if ($request) { $request.Dispose() }
        if ($client) { $client.Dispose() }
        $accessToken = $null
        $headers = $null
        $credentials = $null
    }
}

function ConvertTo-CodexLimitSnapshot {
    param($RateLimits, [datetime]$MeasuredAt)
    $now = [DateTimeOffset]::UtcNow
    $lines = @()
    $shown = @()
    foreach ($window in @($RateLimits.primary, $RateLimits.secondary)) {
        $resetsAt = [DateTimeOffset]::FromUnixTimeSeconds([long]$window.resets_at)
        $length = [double]$window.window_minutes
        $label = if ($length -ge 1440) { '{0}d' -f ($length / 1440) } else { '{0}h' -f ($length / 60) }
        if ($resetsAt -le $now) {
            # The window has rolled over since the measurement, so its old
            # percentage no longer applies.
            $shown += 0
            $lines += ('{0} window: reset {1}; usage since then is not measured yet' -f $label, (Format-LimitResetTime $resetsAt))
        } else {
            $shown += [double]$window.used_percent
            $lines += ('{0} window: {1:0}% used; {2}' -f $label, [double]$window.used_percent, (Format-LimitResetTime $resetsAt))
        }
    }
    [pscustomobject]@{
        UsageDisplay = '{0:0}/{1:0}%' -f $shown[0], $shown[1]
        UsageDetail = $lines -join "`r`n"
        UsageMeasuredAt = $MeasuredAt
    }
}

# Limits belong to the account, not to a process. The session that hit a limit
# is often closed afterwards, so read the newest snapshot from the latest
# rollouts instead of only from live sessions.
function Get-CodexAccountLimitSnapshot {
    $root = Join-Path $env:USERPROFILE '.codex\sessions'
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return $null }
    $best = $null
    $files = @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter 'rollout-*.jsonl' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 8)
    foreach ($file in $files) {
        if ($best -and $file.LastWriteTime -lt $best.UsageMeasuredAt) { break }
        $stream = $null
        try {
            $stream = [System.IO.File]::Open($file.FullName, [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $bytesToRead = [int][math]::Min($stream.Length, 4MB)
            if ($bytesToRead -le 0) { continue }
            [void]$stream.Seek(-$bytesToRead, [System.IO.SeekOrigin]::End)
            $buffer = New-Object byte[] $bytesToRead
            $read = $stream.Read($buffer, 0, $bytesToRead)
            $lines = @([System.Text.Encoding]::UTF8.GetString($buffer, 0, $read) -split "`n")
            for ($index = $lines.Count - 1; $index -ge 0; $index--) {
                if ($lines[$index] -notmatch '"type"\s*:\s*"token_count"' -or $lines[$index] -notmatch '"rate_limits"') { continue }
                try {
                    $entry = $lines[$index] | ConvertFrom-Json -ErrorAction Stop
                    $limits = $entry.payload.rate_limits
                    if ($entry.payload.type -eq 'token_count' -and $limits -and $limits.primary -and $limits.secondary) {
                        $snapshot = ConvertTo-CodexLimitSnapshot $limits ([datetime]$entry.timestamp)
                        if (-not $best -or $snapshot.UsageMeasuredAt -gt $best.UsageMeasuredAt) { $best = $snapshot }
                        break
                    }
                } catch {
                }
            }
        } catch {
        } finally {
            if ($stream) { $stream.Dispose() }
        }
    }
    return $best
}

function Find-CodexResumedRollout {
    # `codex resume` keeps writing to the rollout it was created in, which can
    # be days old, so it is never in the folder for the day the process started.
    param(
        [string]$WorkspacePath,
        [datetime]$Started,
        [string]$SessionId,
        [string[]]$Claimed = @()
    )

    $sessionsRoot = Join-Path $env:USERPROFILE '.codex\sessions'
    if (-not (Test-Path -LiteralPath $sessionsRoot -PathType Container)) { return $null }
    if ($SessionId) {
        return Get-ChildItem -LiteralPath $sessionsRoot -Recurse -File -Filter ('rollout-*-' + $SessionId + '.jsonl') `
            -ErrorAction SilentlyContinue | Select-Object -First 1
    }

    # `--last` takes the most recently updated session of the folder. Look at
    # the last two weeks only, and only at rollouts that began before this
    # process did.
    $candidates = @()
    for ($back = 0; $back -le 14; $back++) {
        $day = (Get-Date).AddDays(-$back)
        $directory = Join-Path (Join-Path (Join-Path $sessionsRoot $day.ToString('yyyy')) $day.ToString('MM')) $day.ToString('dd')
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) { continue }
        foreach ($file in @(Get-ChildItem -LiteralPath $directory -File -Filter 'rollout-*.jsonl' -ErrorAction SilentlyContinue)) {
            if ($Claimed -contains $file.FullName) { continue }
            $stamp = [regex]::Match($file.Name, '^rollout-(\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2})-')
            $created = [datetime]::MinValue
            if (-not $stamp.Success -or -not [datetime]::TryParseExact($stamp.Groups[1].Value, 'yyyy-MM-ddTHH-mm-ss',
                    [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeLocal, [ref]$created)) { continue }
            if ($created -gt $Started) { continue }
            $reader = $null
            try {
                $reader = New-Object System.IO.StreamReader([System.IO.File]::Open($file.FullName,
                    [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite))
                $meta = $reader.ReadLine() | ConvertFrom-Json -ErrorAction Stop
                $source = $meta.payload.source
                $isCli = ($source -is [string]) -and (@('cli', 'vscode') -contains $source) -and
                    (@('', 'codex-tui') -contains [string]$meta.payload.originator)
                $sameWorkspace = (-not $WorkspacePath) -or
                    ([string]$meta.payload.cwd).TrimEnd('\').Equals($WorkspacePath.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)
                if ($isCli -and $sameWorkspace) { $candidates += $file }
            } catch {
            } finally {
                if ($reader) { $reader.Dispose() }
            }
        }
    }
    if ($candidates.Count -eq 0) { return $null }
    # A rollout written to since the process started is the one it resumed.
    # With none, the session is idle and `--last` would have picked the
    # newest one.
    $written = @($candidates | Where-Object { $_.LastWriteTime -gt $Started } | Sort-Object LastWriteTime -Descending)
    if ($written.Count -gt 0) { return $written[0] }
    return ($candidates | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
}

function Get-CodexTranscriptState {
    param(
        [string]$Workspace,
        [string]$Project,
        [datetime]$Started,
        [string]$CommandLine,
        [int]$ProcessId
    )

    $dayDirectory = Join-Path $env:USERPROFILE '.codex\sessions'
    $dayDirectory = Join-Path $dayDirectory $Started.ToString('yyyy')
    $dayDirectory = Join-Path $dayDirectory $Started.ToString('MM')
    $dayDirectory = Join-Path $dayDirectory $Started.ToString('dd')
    $transcript = $null
    $pidKey = [string]$ProcessId
    if ($script:codexTranscriptByPid.ContainsKey($pidKey)) {
        $remembered = [string]$script:codexTranscriptByPid[$pidKey]
        if (Test-Path -LiteralPath $remembered -PathType Leaf) { $transcript = Get-Item -LiteralPath $remembered }
    }

    if (-not $transcript) {
        $files = if (Test-Path -LiteralPath $dayDirectory -PathType Container) {
            @(Get-ChildItem -LiteralPath $dayDirectory -File -Filter 'rollout-*.jsonl' -ErrorAction SilentlyContinue)
        } else { @() }
        $sessionId = ''
        if ($CommandLine -match '(?i)\b([0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12})\b') { $sessionId = $Matches[1] }
        $workspacePath = $Workspace
        if (-not $workspacePath -and $Project -and $Project -ne '(external)') {
            foreach ($root in @($codeProjectsRoot, $projectsRoot)) {
                $candidate = Join-Path $root $Project
                if (Test-Path -LiteralPath $candidate -PathType Container) { $workspacePath = $candidate; break }
            }
        }
        if ($sessionId) {
            $transcript = $files | Where-Object { $_.BaseName -like ('*-' + $sessionId) } | Select-Object -First 1
        }
        if (-not $transcript -and $CommandLine -match '(?i)\s(?:resume|fork)(?:\s|$)') {
            $claimed = @($script:codexTranscriptByPid.GetEnumerator() | Where-Object { $_.Key -ne $pidKey } | ForEach-Object { [string]$_.Value })
            $transcript = Find-CodexResumedRollout -WorkspacePath $workspacePath -Started $Started -SessionId $sessionId -Claimed $claimed
        }
        if (-not $transcript) {
            # Codex names a rollout with the time the CLI session started. On
            # recent builds the JSONL may be materialized (or atomically
            # replaced) several minutes later, which makes the Windows file
            # CreationTime unsuitable for associating it with the process.
            # Prefer the stable timestamp embedded in the rollout filename and
            # retain CreationTime as a compatibility fallback for older names.
            $nearStart = @($files | ForEach-Object {
                $rolloutStarted = $_.CreationTime
                $stamp = [regex]::Match($_.Name,
                    '^rollout-(\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2})-')
                if ($stamp.Success) {
                    $parsedStamp = [datetime]::MinValue
                    if ([datetime]::TryParseExact($stamp.Groups[1].Value,
                        'yyyy-MM-ddTHH-mm-ss',
                        [System.Globalization.CultureInfo]::InvariantCulture,
                        [System.Globalization.DateTimeStyles]::AssumeLocal,
                        [ref]$parsedStamp)) {
                        $rolloutStarted = $parsedStamp
                    }
                }
                [pscustomobject]@{
                    File = $_
                    StartDistance = [math]::Abs(($rolloutStarted - $Started).TotalSeconds)
                }
            } | Where-Object { $_.StartDistance -le 180 } |
                Sort-Object StartDistance)
            foreach ($candidateFile in $nearStart) {
                $candidateFile = $candidateFile.File
                $candidateStream = $null
                $candidateReader = $null
                try {
                    $candidateStream = [System.IO.File]::Open($candidateFile.FullName, [System.IO.FileMode]::Open,
                        [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                    $candidateReader = New-Object System.IO.StreamReader($candidateStream)
                    $meta = $candidateReader.ReadLine() | ConvertFrom-Json -ErrorAction Stop
                    # A terminal session is tagged source=cli by current builds
                    # and source=vscode by older ones; both write originator
                    # codex-tui. A subagent rollout has an object as source, so
                    # requiring a string keeps those out.
                    $rolloutSource = $meta.payload.source
                    $isCli = ($rolloutSource -is [string]) -and
                        (@('cli', 'vscode') -contains $rolloutSource) -and
                        (@('', 'codex-tui') -contains [string]$meta.payload.originator)
                    $sameWorkspace = (-not $workspacePath) -or
                        ([string]$meta.payload.cwd).Equals($workspacePath, [System.StringComparison]::OrdinalIgnoreCase)
                    if ($isCli -and $sameWorkspace) { $transcript = $candidateFile; break }
                } catch {
                } finally {
                    if ($candidateReader) { $candidateReader.Dispose() }
                    if ($candidateStream) { $candidateStream.Dispose() }
                }
            }
        }
        if (-not $transcript) { return $null }
        $script:codexTranscriptByPid[$pidKey] = $transcript.FullName
    }

    $activeModel = ''
    $activeEffort = ''
    [long]$contextTokens = 0
    [long]$contextWindow = 0
    $usageDisplay = [string][char]0x2014
    $usageDetail = 'No Codex usage-limit measurement has been written yet.'
    $usageMeasuredAt = [datetime]::MinValue
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($transcript.FullName, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $bytesToRead = [int][math]::Min($stream.Length, 4MB)
        if ($bytesToRead -gt 0) {
            [void]$stream.Seek(-$bytesToRead, [System.IO.SeekOrigin]::End)
            $buffer = New-Object byte[] $bytesToRead
            $read = $stream.Read($buffer, 0, $bytesToRead)
            $tailText = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $read)
            $lines = @($tailText -split "`n")
            $firstLine = if ($bytesToRead -eq $stream.Length) { 0 } else { 1 }
            for ($index = $firstLine; $index -lt $lines.Count; $index++) {
                $line = $lines[$index]
                if ($line -notmatch '"type"\s*:\s*"(turn_context|event_msg)"') { continue }
                try {
                    $entry = $line | ConvertFrom-Json -ErrorAction Stop
                    if ($entry.type -eq 'turn_context' -and $entry.payload.model) {
                        $activeModel = [string]$entry.payload.model
                        $activeEffort = if ($entry.payload.PSObject.Properties['effort']) { [string]$entry.payload.effort } else { '' }
                    } elseif ($entry.type -eq 'event_msg' -and $entry.payload.type -eq 'token_count' -and $entry.payload.info) {
                        $contextTokens = [long]$entry.payload.info.last_token_usage.total_tokens
                        $contextWindow = [long]$entry.payload.info.model_context_window
                        if ($entry.payload.rate_limits) {
                            $primary = $entry.payload.rate_limits.primary
                            $secondary = $entry.payload.rate_limits.secondary
                            if ($primary -and $secondary) {
                                $snapshot = ConvertTo-CodexLimitSnapshot $entry.payload.rate_limits ([datetime]$entry.timestamp)
                                $usageDisplay = $snapshot.UsageDisplay
                                $usageDetail = $snapshot.UsageDetail
                                $usageMeasuredAt = $snapshot.UsageMeasuredAt
                            }
                        }
                    }
                } catch {
                }
            }
        }
    } catch {
        return $null
    } finally {
        if ($stream) { $stream.Dispose() }
    }
    $threadId = [regex]::Match($transcript.BaseName, '([0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})$').Groups[1].Value
    $threadName = ConvertTo-SessionTitle (Get-CodexThreadName $threadId) 60 3
    return [pscustomobject]@{
        Display = Get-CompactModelName $activeModel
        Exact   = $activeModel
        Title   = $threadName
        TitleSource = if ($threadName) { 'the Codex thread name' } else { '' }
        Effort  = $activeEffort
        ContextTokens = $contextTokens
        ContextWindow = $contextWindow
        UsageDisplay = $usageDisplay
        UsageDetail  = $usageDetail
        UsageMeasuredAt = $usageMeasuredAt
    }
}

function Get-LiveAgentSessions {
    try {
        # Query only processes that can be an agent or one of its launcher
        # ancestors. Enumerating every Windows process delayed the first paint.
        # python.exe is there for Orchestrator sessions, which the workflow
        # controller starts through its own Python processes.
        $processFilter = "Name='claude.exe' OR Name='codex.exe' OR Name='powershell.exe' OR Name='cmd.exe' OR Name='node.exe' OR Name='herdr.exe' OR Name='python.exe'"
        $processRows = @(Get-CimInstance Win32_Process -Filter $processFilter -ErrorAction Stop)
        $byId = @{}
        foreach ($row in $processRows) { $byId[[int]$row.ProcessId] = $row }

        $agentRows = @($processRows | Where-Object {
            $name = [string]$_.Name
            $commandLine = [string]$_.CommandLine
            ($name -ieq 'claude.exe') -or
             (($name -ieq 'codex.exe') -and
             (Test-CodexTerminalCommandLine $commandLine))
        })

        $sessions = @()
        foreach ($agentRow in $agentRows) {
            $terminal = $null
            $cursor = $agentRow
            $seen = @{}
            $paneShell = $null
            $viaController = $false
            while ($cursor -and -not $seen.ContainsKey([int]$cursor.ProcessId)) {
                $seen[[int]$cursor.ProcessId] = $true
                if ([string]$cursor.Name -ieq 'python.exe') { $viaController = $true }
                if ([string]$cursor.Name -ieq 'powershell.exe') { $terminal = $cursor; break }
                # An agent typed by hand into a Herdr pane runs under the
                # pane's own shell (often cmd) with no PowerShell in between.
                if ([string]$cursor.Name -ieq 'herdr.exe' -and $paneShell) { $terminal = $paneShell; break }
                if ([int]$cursor.ProcessId -ne [int]$agentRow.ProcessId) { $paneShell = $cursor }
                $parentId = [int]$cursor.ParentProcessId
                $cursor = if ($byId.ContainsKey($parentId)) { $byId[$parentId] } else { $null }
            }

            # This page is for terminal sessions. App-server and orphaned helper
            # processes are deliberately excluded.
            if (-not $terminal) { continue }
            $terminalCommand = [string]$terminal.CommandLine
            # Herdr starts its shells with the setup as a base64
            # -EncodedCommand, which hides the workspace marker below.
            if ($terminalCommand -match '(?i)-EncodedCommand\s+([A-Za-z0-9+/=]+)') {
                try {
                    $terminalCommand = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Matches[1]))
                } catch {
                }
            }
            $terminalHost = 'Windows Terminal'
            $herdrRow = $null
            $hostCursor = $terminal
            $hostIds = @()
            for ($level = 0; $hostCursor -and $level -lt 6; $level++) {
                $hostIds += [int]$hostCursor.ProcessId
                if ([string]$hostCursor.Name -ieq 'herdr.exe') { $terminalHost = 'Herdr'; $herdrRow = $hostCursor; break }
                $hostParent = [int]$hostCursor.ParentProcessId
                $hostCursor = if ($byId.ContainsKey($hostParent)) { $byId[$hostParent] } else { $null }
            }
            # An Orchestrator session in a Herdr server with no session name
            # belongs to a private pilot server the launcher cannot reach, and
            # those leave old controller sessions running.
            if ($viaController -and $herdrRow -and [string]$herdrRow.CommandLine -notmatch '(?i)--session\s') { continue }
            $workspace = ''
            if ($terminalCommand -match "(?i)AGENT_LAUNCHER_WORKSPACE\s*=\s*'((?:''|[^'])*)'") {
                $workspace = $Matches[1] -replace "''", "'"
            }
            $windowTitle = ''
            if ($terminalCommand -match "(?i)WindowTitle\s*=\s*'((?:''|[^'])*)'") {
                $windowTitle = $Matches[1] -replace "''", "'"
            }
            # Without a launcher marker, Claude's own registry says where the
            # process is working.
            $claudeRecord = $null
            if ([string]$agentRow.Name -ieq 'claude.exe') {
                $claudeRecord = Get-ClaudeSessionRecord -ProcessId ([int]$agentRow.ProcessId) -Started ([datetime]$agentRow.CreationDate)
                if (-not $workspace -and $claudeRecord -and $claudeRecord.Cwd) { $workspace = $claudeRecord.Cwd }
            }
            $project = if ($workspace) { Split-Path -Leaf $workspace } elseif ($windowTitle) {
                ($windowTitle -split '\s{2}\+\s{2}', 2)[0]
            } elseif ($terminalHost -eq 'Herdr') { 'Herdr' } else { '(external)' }

            $agentCommand = [string]$agentRow.CommandLine
            $model = '(default)'
            if ($agentCommand -match '(?i)[''"]?--model[''"]?\s+[''"]?([^''"\s]+)') { $model = $Matches[1] }
            $agentName = if ([string]$agentRow.Name -ieq 'claude.exe') { 'Claude' } else { 'Codex' }
            $currentModel = Get-CompactModelName $model
            $modelDetail = $model
            $modelSource = 'launch command'
            [long]$contextTokens = 0
            [long]$contextWindow = 0
            $usageDisplay = [string][char]0x2014
            $usageDetail = 'No usage-limit measurement is available.'
            $usageMeasuredAt = [datetime]::MinValue
            $autoTitle = ''
            $autoTitleSource = ''
            if ($agentName -eq 'Claude') {
                $registeredSession = if ($claudeRecord) { $claudeRecord.SessionId } else { '' }
                # The transcript sits under the folder the process runs in. An
                # Orchestrator session shows its project but runs in a role folder.
                $transcriptWorkspace = if ($claudeRecord -and $claudeRecord.Cwd) { $claudeRecord.Cwd } else { $workspace }
                $transcriptState = Get-ClaudeTranscriptModel -Workspace $transcriptWorkspace -Project $project `
                    -Started ([datetime]$agentRow.CreationDate) -CommandLine $agentCommand -ProcessId ([int]$agentRow.ProcessId) `
                    -RegisteredSessionId $registeredSession
                if ($transcriptState) {
                    $currentModel = $transcriptState.Display
                    $modelDetail = $transcriptState.Exact
                    $modelSource = 'active Claude session'
                    $autoTitle = $transcriptState.Title
                    $autoTitleSource = $transcriptState.TitleSource
                    $contextTokens = $transcriptState.ContextTokens
                    $contextWindow = $transcriptState.ContextWindow
                    $usageDisplay = $transcriptState.UsageDisplay
                    $usageDetail = $transcriptState.UsageDetail
                    $usageMeasuredAt = $transcriptState.UsageMeasuredAt
                }
            } else {
                $transcriptState = Get-CodexTranscriptState -Workspace $workspace -Project $project `
                    -Started ([datetime]$agentRow.CreationDate) -CommandLine $agentCommand -ProcessId ([int]$agentRow.ProcessId)
                if ($transcriptState) {
                    $autoTitle = $transcriptState.Title
                    $autoTitleSource = $transcriptState.TitleSource
                    if ($transcriptState.Display) {
                        $currentModel = $transcriptState.Display
                        $modelDetail = $transcriptState.Exact
                        $modelSource = 'active Codex session'
                    }
                    $contextTokens = $transcriptState.ContextTokens
                    $contextWindow = $transcriptState.ContextWindow
                    $usageDisplay = $transcriptState.UsageDisplay
                    $usageDetail = $transcriptState.UsageDetail
                    $usageMeasuredAt = $transcriptState.UsageMeasuredAt
                }
            }
            # A name given to the tab in Herdr is the user's own, so it beats
            # anything derived from the transcript.
            $herdrPane = [pscustomobject]@{ Exe = ''; Session = ''; PaneId = ''; TabTitle = '' }
            if ($herdrRow) {
                # $seen holds every process from the agent up to its terminal and
                # $hostIds the ones above it up to Herdr, the pane's shell among them.
                $herdrPane = Get-HerdrPaneInfo -HerdrRow $herdrRow -ProcessIds @(@($seen.Keys | ForEach-Object { [int]$_ }) + $hostIds)
                if ($herdrPane.TabTitle) {
                    $autoTitle = $herdrPane.TabTitle
                    $autoTitleSource = 'the tab name in Herdr'
                }
            }
            $launchDetails = Get-LiveLaunchDetails -Agent $agentName -CommandLine $agentCommand
            # Both CLIs can change effort mid-session, so the transcript's latest
            # turn wins over the launch flag. Neither says which level "default"
            # resolves to until the first turn has been written.
            $effort = 'default'
            $effortSource = 'no effort flag at launch; the CLI default applies'
            if ($launchDetails.Effort) {
                $effort = $launchDetails.Effort
                $effortSource = 'launch command'
            }
            if ($transcriptState -and $transcriptState.Effort) {
                $effort = $transcriptState.Effort
                $effortSource = 'active {0} session' -f $agentName
            }
            $sessions += [pscustomobject]@{
                Agent       = $agentName
                Project     = $project
                Workspace   = $workspace
                WindowTitle = $windowTitle
                TerminalHost = $terminalHost
                HerdrExe    = $herdrPane.Exe
                HerdrSession = $herdrPane.Session
                HerdrEnvKey = $herdrPane.EnvKey
                HerdrPane   = $herdrPane.PaneId
                StartModel  = $model
                Model       = $currentModel
                ModelDetail = $modelDetail
                ModelSource = $modelSource
                AutoTitle   = $autoTitle
                AutoTitleSource = $autoTitleSource
                Effort      = $effort
                EffortSource = $effortSource
                ContextTokens = $contextTokens
                ContextWindow = $contextWindow
                ContextDisplay = Format-ContextTokens $contextTokens $contextWindow
                ContextHealth = Get-ContextHealth $contextTokens $contextWindow
                UsageDisplay = $usageDisplay
                UsageDetail = $usageDetail
                UsageMeasuredAt = $usageMeasuredAt
                Permission = $launchDetails.Permission
                Started     = [datetime]$agentRow.CreationDate
                AgentId     = [int]$agentRow.ProcessId
                TerminalId  = [int]$terminal.ProcessId
                SessionKey  = ('{0}:{1}' -f [int]$agentRow.ProcessId, ([datetime]$agentRow.CreationDate).Ticks)
            }
        }
        # Limits are account-wide, not session-specific. An idle transcript can
        # contain an old snapshot, so show the freshest measurement on every
        # live row for the same agent.
        $codexAccount = if (@($sessions | Where-Object { $_.Agent -eq 'Codex' }).Count -gt 0) { Get-CodexAccountLimitSnapshot } else { $null }
        foreach ($accountAgent in @('Claude', 'Codex')) {
            $candidates = @($sessions | Where-Object {
                $_.Agent -eq $accountAgent -and $_.UsageDisplay -ne ([string][char]0x2014) -and $_.UsageMeasuredAt -gt [datetime]::MinValue
            })
            if ($accountAgent -eq 'Codex' -and $codexAccount) { $candidates += $codexAccount }
            $freshest = $candidates | Sort-Object UsageMeasuredAt -Descending | Select-Object -First 1
            if ($freshest) {
                foreach ($session in @($sessions | Where-Object { $_.Agent -eq $accountAgent })) {
                    $session.UsageDisplay = $freshest.UsageDisplay
                    $session.UsageDetail = $freshest.UsageDetail + ("`r`nMeasured {0:g}." -f $freshest.UsageMeasuredAt)
                    $session.UsageMeasuredAt = $freshest.UsageMeasuredAt
                }
            }
        }
        return @($sessions | Sort-Object Started -Descending)
    } catch {
        return @()
    }
}

# `resume --last` cannot attach a second TUI to a thread that is still open.
# Catch the common case before opening another terminal that can only fail. A
# picker is deliberately not blocked: it may choose a different inactive thread.
function Find-ActiveAgentTerminal {
    param([Parameter(Mandatory)]$Preview)
    if ($Preview.StartMode -ne 'Continue last') { return $null }
    foreach ($session in @(Get-LiveAgentSessions)) {
        if ($session.Agent -ne $Preview.Agent) { continue }
        $sameWorkspace = $session.Workspace -and (Test-SamePath $session.Workspace $Preview.WorkingDirectory)
        $legacyMatch = (-not $session.Workspace) -and ($session.Project -eq $Preview.TerminalTitle)
        if ($sameWorkspace -or $legacyMatch) { return $session }
    }
    return $null
}

# Windows Terminal is the intended host: the live-session tab walk below assumes
# every session is a tab inside one Terminal window. Plain powershell.exe only
# lands there when Windows hands the console off, and with the default terminal
# left as "let Windows decide" a machine with no Terminal already running
# decides against it - the session opens in conhost instead, blue and tabless.
# Naming wt.exe takes the guess out.

# Sessions share one Terminal window of their own, kept apart from whatever
# else the user has open in Terminal.
$script:agentWindowName = 'agent-sessions'

function ConvertTo-WtArgument {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    # wt splits its own command line on ';' and eats '"' as it re-joins the
    # rest, so both have to reach it escaped. Left alone, a semicolon ends the
    # command there and wt drops everything after it without a word: the
    # workspace marker survives, the title and the agent invocation do not.
    ($Value -replace '"', '\"') -replace ';', '\;'
}

function Start-AgentConsole {
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$Title,
        [string]$TabTitle = ''
    )
    if ($script:launchTerminalHost -eq 'Herdr') {
        # This outer Windows Terminal tab belongs to the shared Herdr client;
        # individual project names remain visible in Herdr's Spaces sidebar.
        $Title = 'Herdr'
        Import-HerdrEntry
        $hostPreview = Get-HerdrHostPreview -WorkingDirectory $WorkingDirectory -AdapterPath $HerdrAdapter -SharedSession
        $null = Test-HerdrHostReadiness $hostPreview
        $workspaceResult = Start-HerdrWorkspace -WorkingDirectory $WorkingDirectory -Command $Command -AdapterPath $HerdrAdapter
        if (-not ($workspaceResult.PSObject.Properties['needs_client'] -and $workspaceResult.needs_client)) {
            # The pane exists now, so name its tab. A failure here must not look
            # like a failed launch; the live view tries again.
            if ($TabTitle -and $workspaceResult.PSObject.Properties['pane_id']) {
                try {
                    $server = Get-LauncherHerdrServer
                    if ($server -and (Set-HerdrTabTitle -Exe $server.Exe -Session $server.Session -EnvKey $server.EnvKey -PaneId ([string]$workspaceResult.pane_id) -Title $TabTitle)) {
                        $script:herdrTitleApplied['{0}|{1}|{2}' -f $server.Session, $workspaceResult.pane_id, $TabTitle] = $true
                    }
                } catch {
                }
            }
            return
        }
        # First use bootstraps one stable launcher-owned Herdr TUI. Later
        # launches create a workspace through its running session API above.
        $hostPreview = Get-HerdrHostPreview -WorkingDirectory $WorkingDirectory -Command $Command -AdapterPath $HerdrAdapter -SharedSession -LaunchShared
        $Command = Get-HerdrConsoleCommand $hostPreview
    }
    if (Get-Command 'wt.exe' -CommandType Application -ErrorAction SilentlyContinue) {
        # Windows PowerShell joins an -ArgumentList array on spaces and quotes
        # none of it, which strands every value holding a space: '>_  Project'
        # reaches wt as two arguments and the tab never opens. So the command
        # line is written out whole here, each value quoted deliberately.
        # Quoting the PowerShell command also stops wt collapsing the double
        # spaces that the window title itself uses as a separator.
        #
        # A named window, not '-w 0'. '0' means the most recently used Terminal
        # window, which is whichever one the user happened to touch last: the
        # session lands as a tab in the middle of their own work, behind
        # whatever is in front, and reads as nothing having opened at all.
        # Naming the window keeps sessions gathered together - the tab walk
        # still wants that - in a window of their own, and the first launch
        # creates it, so something visibly appears.
        # Keep the launcher's title visible. Both agent TUIs publish their own
        # dynamic titles; once that replaces ours, two sessions in one folder
        # become indistinguishable and it is unsafe to type a handoff request.
        $wtLine = '-w {0} nt --title "{1}" --suppressApplicationTitle -d "{2}" powershell.exe -NoLogo -NoExit -Command "{3}"' -f
                  $script:agentWindowName,
                  (ConvertTo-WtArgument $Title),
                  (ConvertTo-WtArgument $WorkingDirectory),
                  (ConvertTo-WtArgument $Command)
        # Hand the foreground right to Terminal. Without it Windows can add the
        # tab but leave the terminal wherever it was in the stack, which looks
        # like a no-op. The launcher itself remains open behind the terminal.
        try { [void][Launcher.WindowFocus]::AllowSetForegroundWindow(0xFFFFFFFF) } catch { }
        Start-Process -FilePath 'wt.exe' -ArgumentList $wtLine
        return
    }
    # No Windows Terminal on this machine, so take whatever host Windows picks.
    Start-Process -FilePath "$PSHOME\powershell.exe" -WorkingDirectory $WorkingDirectory `
        -ArgumentList @('-NoLogo', '-NoExit', '-Command', $Command)
}

function Start-AgentTerminal {
    param(
        [Parameter(Mandatory)][string]$SelectedAgent,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [AllowEmptyCollection()][string[]]$ContextDirectories = @(),
        [string]$SelectedModel = '',
        [string]$SelectedMode = '',
        [string]$StartMode = '',
        [string]$OpeningPrompt = '',
        [string]$SelectedEffort = '',
        [string]$SelectedPersona = '',
        [string]$SelectedWeb = '',
        [string]$SessionTitle = ''
    )
    $preview = Get-LaunchPreview -SelectedAgent $SelectedAgent -WorkingDirectory $WorkingDirectory -ContextDirectories $ContextDirectories -SelectedModel $SelectedModel -SelectedMode $SelectedMode -StartMode $StartMode -OpeningPrompt $OpeningPrompt -SelectedEffort $SelectedEffort -SelectedPersona $SelectedPersona -SelectedWeb $SelectedWeb
    $activeTerminal = Find-ActiveAgentTerminal $preview
    if ($activeTerminal) {
        throw ("The latest {0} session for '{1}' is already open in another terminal. " +
               "Switch to the existing '{1}' window, or close it before choosing Continue last.") -f
              $preview.Agent, $preview.TerminalTitle
    }
    # The project and agent are not unique: several fresh sessions may run in
    # the same folder. This marker travels in the PowerShell command line, so
    # Live sessions can recover it and match one terminal tab exactly.
    $sessionMarker = [guid]::NewGuid().ToString('N').Substring(0, 6)
    $preview.WindowTitle = '{0}  #{1}' -f $preview.WindowTitle, $sessionMarker
    # A title typed at launch is kept under the marker. Live sessions read it
    # back from the terminal title, so it survives a launcher restart. Not
    # being able to save it does not stop the session from starting.
    $SessionTitle = ([string]$SessionTitle).Trim()
    if ($SessionTitle.Length -gt 80) { $SessionTitle = $SessionTitle.Substring(0, 80).TrimEnd() }
    if ($SessionTitle) {
        $script:sessionTitles['marker:' + $sessionMarker] = $SessionTitle
        [void](Save-SessionTitles)
    }
    $quotedTitle = "'" + $preview.WindowTitle.Replace("'", "''") + "'"
    $quotedWork  = "'" + $preview.WorkingDirectory.Replace("'", "''") + "'"
    $quotedExe   = "'" + $preview.Executable.Replace("'", "''") + "'"
    $quotedArgs  = @($preview.Arguments | ForEach-Object { "'" + $_.Replace("'", "''") + "'" })
    $invoke  = (@('&', $quotedExe) + $quotedArgs) -join ' '
    # Build with -f, not array concatenation: ',' binds tighter than '+', so
    # @('prefix ' + $a, $b) collapses into a single space-joined string and the
    # statement separator is silently lost.
    # The marker makes future active-session checks exact even when two folders
    # on different drives share the same leaf name.
    $command = '$env:AGENT_LAUNCHER_WORKSPACE = {0}; $Host.UI.RawUI.WindowTitle = {1}; {2}' -f $quotedWork, $quotedTitle, $invoke
    Start-AgentConsole -Command $command -WorkingDirectory $preview.WorkingDirectory -Title $preview.WindowTitle -TabTitle $SessionTitle
}

# ---------------------------------------------------------------- handoff ---
# A handoff moves the work to a fresh session, not the conversation. The
# receiving agent is given one short file: who handed over to whom, a status the
# old session wrote about itself (or one typed by hand), and a repository
# snapshot taken here. No transcript is read to make it.

$handoffFolder = '.agent\handoffs'
$handoffHeadings = @('Goal', 'Done', 'In progress', 'Next steps', 'Open questions and risks', 'Key files')
$handoffStatusChoices = @('Session writes it', 'I write it')
# Past this a status is no longer a summary. It is cut rather than handed on as
# a transcript under another name.
$handoffStatusMaxLines = 120

function Write-Utf8Text {
    param([Parameter(Mandatory)][string]$Path, [AllowEmptyString()][string]$Text)
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $encoding)
}

function ConvertTo-YamlText {
    param([AllowEmptyString()][string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

# Git gets a deadline: a work folder on a share can be slow to answer, and the
# launcher window waits on it.
function Invoke-GitText {
    param([Parameter(Mandatory)][string]$WorkingDirectory, [Parameter(Mandatory)][string]$Arguments)
    $git = Get-Command git.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $git) { return $null }
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $git.Path
    $info.Arguments = $Arguments
    $info.WorkingDirectory = $WorkingDirectory
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.CreateNoWindow = $true
    $info.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    # 'git status' refreshes the index and takes its lock to do so. An agent
    # running git in the same folder at that moment would fail on the lock.
    $info.EnvironmentVariables['GIT_OPTIONAL_LOCKS'] = '0'
    $process = $null
    try {
        $process = [System.Diagnostics.Process]::Start($info)
        $output = $process.StandardOutput.ReadToEndAsync()
        [void]$process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(5000)) {
            try { $process.Kill() } catch { }
            return $null
        }
        if ($process.ExitCode -ne 0 -or -not $output.Wait(2000)) { return $null }
        return ([string]$output.Result).TrimEnd()
    } catch {
        return $null
    } finally {
        if ($process) { try { $process.Dispose() } catch { } }
    }
}

function Get-HandoffRepositorySnapshot {
    param([Parameter(Mandatory)][string]$WorkingDirectory)
    $status = Invoke-GitText -WorkingDirectory $WorkingDirectory -Arguments 'status --short --branch'
    if ($null -eq $status) { return @('Not a git repository, or git did not answer in time.') }
    $statusLines = @($status -split '\r?\n' | Where-Object { $_ })
    $shown = @($statusLines | Select-Object -First 40)
    if ($statusLines.Count -gt $shown.Count) { $shown += ('... and {0} more' -f ($statusLines.Count - $shown.Count)) }
    $snapshot = @('git status --short --branch:', '', '```text') + $shown + @('```')
    $log = Invoke-GitText -WorkingDirectory $WorkingDirectory -Arguments 'log --oneline --no-decorate -n 8'
    if ($log) {
        $snapshot += @('', 'Recent commits:', '', '```text') + @($log -split '\r?\n' | Where-Object { $_ }) + @('```')
    } else {
        $snapshot += @('', 'No commits yet.')
    }
    return $snapshot
}

function Format-HandoffDocument {
    param(
        [Parameter(Mandatory)]$Handoff,
        [ValidateSet('pending', 'agent', 'manual', 'none')][string]$StatusSource = 'pending',
        [AllowEmptyCollection()][string[]]$StatusLines = @()
    )
    $toModel = if ($Handoff.ToModel) { $Handoff.ToModel } else { '(agent default)' }
    $toEffort = if ($Handoff.ToEffort) { $Handoff.ToEffort } else { $effortDefaultLabel }
    $lines = @(
        '---',
        ('handoff: ' + (ConvertTo-YamlText $Handoff.Id)),
        ('created: ' + (ConvertTo-YamlText $Handoff.Created.ToString('yyyy-MM-ddTHH:mm:sszzz'))),
        ('project: ' + (ConvertTo-YamlText $Handoff.Project)),
        ('workspace: ' + (ConvertTo-YamlText $Handoff.WorkingDirectory)),
        ('from_agent: ' + (ConvertTo-YamlText $Handoff.FromAgent)),
        ('from_model: ' + (ConvertTo-YamlText $Handoff.FromModel)),
        ('from_permissions: ' + (ConvertTo-YamlText $Handoff.FromPermission)),
        ('to_agent: ' + (ConvertTo-YamlText $Handoff.ToAgent)),
        ('to_model: ' + (ConvertTo-YamlText $toModel)),
        ('to_permissions: ' + (ConvertTo-YamlText $Handoff.ToMode)),
        ('to_effort: ' + (ConvertTo-YamlText $toEffort)),
        ('status_source: ' + $StatusSource),
        '---',
        '',
        ('# Handoff: {0} to {1}' -f $Handoff.FromAgent, $Handoff.ToAgent),
        '',
        '## For the receiving agent',
        '',
        ('- You are taking over work that a {0} session was doing in this folder. Its conversation is deliberately not included.' -f $Handoff.FromAgent),
        '- Treat the status below as a briefing, not as verified fact. Check it against the files and the repository before relying on it.',
        "- Follow this project's own AGENTS.md or CLAUDE.md as usual.",
        '- Begin by saying in a few lines what you are taking over. Then continue with Next steps, unless the status or the note says to wait for the user.',
        '',
        '## Status',
        ''
    )
    switch ($StatusSource) {
        'pending' {
            $lines += ('_Waiting for the {0} session to write {1}. If this line is still here, the handoff did not finish: ask the user how to go on._' -f $Handoff.FromAgent, $Handoff.StatusRelativePath)
        }
        'agent' {
            $lines += ('_Written by the {0} session itself at handoff time._' -f $Handoff.FromAgent)
            $lines += ''
            $lines += $StatusLines
        }
        'manual' {
            $lines += '_Written by hand in the launcher. The previous session did not write this itself._'
            $lines += ''
            $lines += $StatusLines
        }
        default {
            $lines += '_No status was given. Work out where things stand from the repository snapshot below, and ask the user what comes next._'
        }
    }
    $lines += ''
    $lines += '## Note from the user'
    $lines += ''
    if ($Handoff.Note) { $lines += @($Handoff.Note -split '\r?\n') } else { $lines += '(none)' }
    $lines += ''
    $lines += '## Repository snapshot'
    $lines += ''
    $lines += '_Taken by the launcher at handoff time, not written by an agent._'
    $lines += ''
    $lines += @($Handoff.Snapshot)
    return (($lines -join "`r`n").TrimEnd() + "`r`n")
}

# Written straight away with the status still pending, so the file exists and
# says what it is waiting for even if the launcher is closed halfway.
function New-HandoffFile {
    param(
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][ValidateSet('Claude', 'Codex')][string]$FromAgent,
        [string]$FromModel = '',
        [string]$FromPermission = '',
        [Parameter(Mandatory)][ValidateSet('Claude', 'Codex')][string]$ToAgent,
        [string]$ToModel = '',
        [string]$ToMode = '',
        [string]$ToEffort = '',
        [string]$Note = ''
    )
    $workPath = (Resolve-Path -LiteralPath $WorkingDirectory).ProviderPath
    $folder = Join-Path $workPath $handoffFolder
    [void][System.IO.Directory]::CreateDirectory($folder)
    $created = Get-Date
    $baseId = '{0}-{1}-to-{2}' -f $created.ToString('yyyyMMdd-HHmmss'), $FromAgent.ToLowerInvariant(), $ToAgent.ToLowerInvariant()
    $id = $baseId
    $suffix = 2
    while (Test-Path -LiteralPath (Join-Path $folder ($id + '.md'))) {
        $id = '{0}-{1}' -f $baseId, $suffix
        $suffix++
    }
    $project = Split-Path -Leaf $workPath
    if (-not $project) { $project = $workPath.Trim('\') }
    $relative = ($handoffFolder -replace '\\', '/') + '/' + $id
    $handoff = [pscustomobject]@{
        Id                 = $id
        Created            = $created
        WorkingDirectory   = $workPath
        Project            = $project
        FromAgent          = $FromAgent
        FromModel          = $FromModel
        FromPermission     = $FromPermission
        ToAgent            = $ToAgent
        ToModel            = $ToModel
        ToMode             = $ToMode
        ToEffort           = $ToEffort
        Note               = ([string]$Note).Trim()
        Snapshot           = @(Get-HandoffRepositorySnapshot -WorkingDirectory $workPath)
        Path               = Join-Path $folder ($id + '.md')
        RelativePath       = $relative + '.md'
        StatusPath         = Join-Path $folder ($id + '.status.md')
        StatusRelativePath = $relative + '.status.md'
    }
    Write-Utf8Text -Path $handoff.Path -Text (Format-HandoffDocument -Handoff $handoff -StatusSource 'pending')
    return $handoff
}

# Fills in the status and removes the scratch file the old session wrote it to.
function Complete-HandoffFile {
    param(
        [Parameter(Mandatory)]$Handoff,
        [Parameter(Mandatory)][ValidateSet('agent', 'manual', 'none')][string]$StatusSource,
        [AllowEmptyString()][string]$StatusText = ''
    )
    $source = $StatusSource
    $lines = @()
    $trimmed = ([string]$StatusText).Trim()
    if (-not $trimmed) { $source = 'none' }
    if ($source -ne 'none') {
        # The status sits under the file's own '## Status', so a heading the
        # agent wrote at level one or two would end that section early.
        $inFence = $false
        foreach ($line in @($trimmed -split '\r?\n')) {
            $text = $line
            if ($text -match '^\s*(```|~~~)') {
                $inFence = -not $inFence
            } elseif (-not $inFence -and $text -match '^#{1,2}\s') {
                $text = $text -replace '^#{1,2}', '###'
            }
            $lines += $text
        }
        if ($lines.Count -gt $handoffStatusMaxLines) {
            $lines = @($lines[0..($handoffStatusMaxLines - 1)]) +
                @('', ('_Cut at {0} lines by the launcher. A handoff status should be short._' -f $handoffStatusMaxLines))
        }
    }
    Write-Utf8Text -Path $Handoff.Path -Text (Format-HandoffDocument -Handoff $Handoff -StatusSource $source -StatusLines $lines)
    if (Test-Path -LiteralPath $Handoff.StatusPath -PathType Leaf) {
        try { Remove-Item -LiteralPath $Handoff.StatusPath -Force -ErrorAction Stop } catch { }
    }
}

function Remove-HandoffFiles {
    param([Parameter(Mandatory)]$Handoff)
    foreach ($path in @($Handoff.Path, $Handoff.StatusPath)) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            try { Remove-Item -LiteralPath $path -Force -ErrorAction Stop } catch { }
        }
    }
}

function Read-HandoffStatus {
    param([Parameter(Mandatory)][string]$Path)
    $stream = $null
    $reader = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $true)
        return $reader.ReadToEnd()
    } catch {
        return ''
    } finally {
        if ($reader) { $reader.Dispose() }
        if ($stream) { $stream.Dispose() }
    }
}

# The old session's status counts as written once the file has content and has
# stopped changing, so a write made in several steps is not taken halfway.
function Get-HandoffStatusStamp {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    try {
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($item.Length -le 0) { return '' }
        return '{0}|{1}' -f $item.Length, $item.LastWriteTimeUtc.Ticks
    } catch {
        return ''
    }
}

function Get-HandoffStatusTemplate {
    $lines = @()
    foreach ($heading in $handoffHeadings) { $lines += @(('### ' + $heading), '', '') }
    return (($lines -join "`r`n").TrimEnd() + "`r`n")
}

# A template sent back untouched is no status at all, and the file says so
# rather than presenting six empty headings as a briefing.
function Test-HandoffStatusEmpty {
    param([AllowEmptyString()][string]$Text)
    foreach ($line in @(([string]$Text) -split '\r?\n')) {
        $trimmed = $line.Trim()
        if (-not $trimmed) { continue }
        if ($trimmed -match '^#{1,6}\s*(.+)$' -and ($handoffHeadings -contains $Matches[1].Trim())) { continue }
        return $false
    }
    return $true
}

# Typed into the old session as a single line, so it has to stay plain: no line
# breaks, nothing that opens a slash command, and no at sign, which opens a file
# picker in both CLIs.
function Get-HandoffRequest {
    param([Parameter(Mandatory)]$Handoff)
    $headings = @($handoffHeadings | ForEach-Object { '### ' + $_ }) -join ', '
    return ('Handoff request from Agent Project Launcher: this work is moving to a new {0} session that will not see this conversation. ' +
            'Write a short status of the work in this session to the file {1}, using exactly these Markdown headings: {2}. ' +
            'Finish the current safe step, save work already in progress, and do not begin another long step. ' +
            'Be concrete and brief, at most 60 lines, with no transcript and no secrets. Write only that file, then stop.') -f
           $Handoff.ToAgent, $Handoff.StatusRelativePath, $headings
}

# SendKeys reads + ^ % ~ ( ) { } [ ] as key names. Braced, each is typed as itself.
function ConvertTo-SendKeysText {
    param([AllowEmptyString()][string]$Text)
    $flat = $Text -replace '\s*\r?\n\s*', ' '
    return [regex]::Replace($flat, '[+^%~(){}\[\]]', '{$0}')
}

# The receiving agent's first message. The file does the explaining; this only
# points at it, relative to the work folder when it lives there.
function Get-HandoffPrompt {
    param([Parameter(Mandatory)][string]$HandoffPath, [Parameter(Mandatory)][string]$WorkingDirectory)
    $reference = $HandoffPath
    $root = $WorkingDirectory.TrimEnd('\') + '\'
    if ($HandoffPath.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        $reference = $HandoffPath.Substring($root.Length) -replace '\\', '/'
    }
    return ('You are taking over from another agent session. Read the handoff file {0} first and follow the instructions in it.' -f $reference)
}

# A relative handoff path is read against the work folder first, since that is
# where the launcher writes them, and against the current directory second.
function Resolve-HandoffFilePath {
    param([Parameter(Mandatory)][string]$Value, [Parameter(Mandatory)][string]$WorkingDirectory)
    $candidates = if ([System.IO.Path]::IsPathRooted($Value)) { @($Value) } else {
        @((Join-Path $WorkingDirectory $Value), (Join-Path (Get-Location).ProviderPath $Value))
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return (Resolve-Path -LiteralPath $candidate).ProviderPath }
    }
    throw "Handoff file '$Value' was not found in the work folder or the current directory."
}

# ------------------------------------------------------- command-line mode ---

function Import-OrchestratorEntry {
    if (Get-Command Get-OrchestratorPreview -ErrorAction SilentlyContinue) { return }
    $entryPath = Join-Path $PSScriptRoot 'OrchestratorEntry.ps1'
    if (-not (Test-Path -LiteralPath $entryPath -PathType Leaf)) { throw 'The optional Orchestrator adapter module is not installed.' }
    . $entryPath
    # Dot-sourcing inside this function keeps functions local to it. Export the
    # three entry functions into the script scope without loading private paths
    # or controller configuration for an Ordinary session.
    foreach ($entryName in @('ConvertTo-OrchestratorArgument','Resolve-OrchestratorAdapterPath','Get-OrchestratorPreview','Test-OrchestratorReadiness','Start-OrchestratorTerminal')) {
        Set-Item -Path ('Function:script:' + $entryName) -Value (Get-Item ('Function:' + $entryName)).ScriptBlock
    }
}

function Import-HerdrEntry {
    Import-OrchestratorEntry
    $entryPath = Join-Path $PSScriptRoot 'HerdrEntry.ps1'
    if (-not (Test-Path -LiteralPath $entryPath -PathType Leaf)) { throw 'The optional Herdr host module is not installed.' }
    . $entryPath
    foreach ($entryName in @('Get-HerdrHostPreview','Test-HerdrHostReadiness','Start-HerdrWorkspace','Get-HerdrConsoleCommand')) {
        Set-Item -Path ('Function:script:' + $entryName) -Value (Get-Item ('Function:' + $entryName)).ScriptBlock
    }
}

function Add-TerminalHostPreview {
    param([Parameter(Mandatory)]$Preview)
    if ($script:launchTerminalHost -eq 'Herdr') {
        Import-HerdrEntry
        $hostPreview = Get-HerdrHostPreview -WorkingDirectory $Preview.WorkingDirectory -AdapterPath $HerdrAdapter -SharedSession:($script:launchTerminalHost -eq 'Herdr')
        $null = Test-HerdrHostReadiness $hostPreview
        $Preview | Add-Member -NotePropertyName TerminalHost -NotePropertyValue $hostPreview.TerminalHost
    }
    return $Preview
}

if ($TerminalHost -ne 'Terminal' -or $HerdrAdapter -or $SessionRole -eq 'Orchestrator' -or $OrchestratorAdapter -or $Agent -or $Project -or $Context -or $Model -or $Mode -or $Start -or $Prompt -or $Effort -or $Persona -or $Web -or $HandoffFile -or $DryRun) {
    if (-not $Agent)   { throw 'Direct or dry-run mode requires -Agent.' }
    if (-not $Project) { throw 'Direct or dry-run mode requires -Project.' }
    $workPath = Resolve-WorkspacePath $Project
    $contextPaths = @()
    if ($Context) { $contextPaths = @($Context | ForEach-Object { Resolve-WorkspacePath $_ -AllowAnywhere }) }
    if ($HerdrAdapter -and $TerminalHost -ne 'Herdr') { throw '-HerdrAdapter requires a Herdr terminal host.' }
    if ($HandoffFile -and $TerminalHost -eq 'Herdr') { throw 'Launcher handoff automation uses Terminal. Start a new Herdr session instead.' }
    if ($SessionRole -eq 'Orchestrator') {
        [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
        Import-OrchestratorEntry
        $contextPaths = @(Get-OrchestratorContextPaths -ProjectPath $workPath -Attached $contextPaths)
        $preview = Get-OrchestratorPreview -SelectedAgent $Agent -WorkingDirectory $workPath -AdapterPath $OrchestratorAdapter -Contexts $contextPaths -Model (Get-ModelSlug $Model) -Mode $Mode -Start $Start -Prompt $Prompt -Effort $Effort -Persona $Persona -Web $Web -Handoff $HandoffFile
        if ($DryRun) {
            $null = Test-OrchestratorReadiness $preview
            Add-TerminalHostPreview $preview | ConvertTo-Json -Depth 5
        } else { $null = Start-OrchestratorTerminal $preview }
        exit 0
    }
    if ($OrchestratorAdapter) { throw '-OrchestratorAdapter requires -SessionRole Orchestrator.' }
    if ($HandoffFile) {
        # The handoff file is the first message, so a prompt of its own has
        # nowhere to go, and a resumed session would already have its history.
        if ($Prompt) { throw 'Pass either -Prompt or -HandoffFile, not both.' }
        if ($Start -and $Start -ne $startNewLabel) { throw 'A handoff always starts a new session; leave -Start out.' }
        $handoffPath = Resolve-HandoffFilePath -Value $HandoffFile -WorkingDirectory $workPath
        $Prompt = Get-HandoffPrompt -HandoffPath $handoffPath -WorkingDirectory $workPath
        $Start = $startNewLabel
    }
    if ($DryRun) {
        $preview = Get-LaunchPreview -SelectedAgent $Agent -WorkingDirectory $workPath -ContextDirectories $contextPaths -SelectedModel $Model -SelectedMode $Mode -StartMode $Start -OpeningPrompt $Prompt -SelectedEffort $Effort -SelectedPersona $Persona -SelectedWeb $Web
        Add-TerminalHostPreview $preview | ConvertTo-Json -Depth 5
        exit 0
    }
    Start-AgentTerminal -SelectedAgent $Agent -WorkingDirectory $workPath -ContextDirectories $contextPaths -SelectedModel $Model -SelectedMode $Mode -StartMode $Start -OpeningPrompt $Prompt -SelectedEffort $Effort -SelectedPersona $Persona -SelectedWeb $Web
    exit 0
}

# -------------------------------------------------------------------- gui ---

[System.Windows.Forms.Application]::EnableVisualStyles()

trap {
    if ($Agent -or $Project -or $DryRun) {
        [Console]::Error.WriteLine("Launcher failed: $($_.Exception.Message) at line $($_.InvocationInfo.ScriptLineNumber)")
        exit 1
    }
    [void][System.Windows.Forms.MessageBox]::Show(
        "$($_.Exception.Message)`n`nAt: $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)",
        'Launcher failed to start', 'OK', 'Error')
    exit 1
}

# ------------------------------------------------------------------ theme ---
# A terminal, not a dialog: one dark canvas, a monospaced grid, and colour
# carrying meaning rather than decoration. Grey is what a field is called,
# green is what it currently is, blue is structure and the primary action.

$theme = @{
    Bg      = [System.Drawing.Color]::FromArgb(11, 14, 20)
    Panel   = [System.Drawing.Color]::FromArgb(13, 17, 23)
    Field   = [System.Drawing.Color]::FromArgb(22, 27, 34)
    Border  = [System.Drawing.Color]::FromArgb(48, 54, 61)
    Head    = [System.Drawing.Color]::FromArgb(201, 209, 217)
    Section = [System.Drawing.Color]::FromArgb(88, 166, 255)
    Claude  = [System.Drawing.Color]::FromArgb(217, 119, 48)
    Label   = [System.Drawing.Color]::FromArgb(139, 148, 158)
    Value   = [System.Drawing.Color]::FromArgb(63, 185, 80)
    Warning = [System.Drawing.Color]::FromArgb(210, 153, 34)
    Muted   = [System.Drawing.Color]::FromArgb(110, 118, 129)
    Danger  = [System.Drawing.Color]::FromArgb(248, 81, 73)
}

# A missing family falls back silently to a proportional face, which would
# break the column alignment the whole layout is built on. Pick a real one.
$installedFonts = @((New-Object System.Drawing.Text.InstalledFontCollection).Families | ForEach-Object { $_.Name })
$monoName = 'Consolas'
foreach ($candidate in @('Cascadia Mono', 'Consolas', 'Lucida Console', 'Courier New')) {
    if ($installedFonts -contains $candidate) { $monoName = $candidate; break }
}
$fontBase = New-Object System.Drawing.Font($monoName, 10)
$fontHead = New-Object System.Drawing.Font($monoName, 11)

# Windows paints the title bar, so it is the one surface the palette cannot
# reach from inside. Ask the compositor for the dark one; ignored pre-Win10 20H1.
try {
    Add-Type -Namespace Launcher -Name Dwm -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("dwmapi.dll")]
public static extern int DwmSetWindowAttribute(System.IntPtr hwnd, int attribute, ref int value, int size);
'@ -ErrorAction Stop
} catch { }

function Set-DarkTitleBar {
    param($Window)
    try {
        $on = 1
        [void][Launcher.Dwm]::DwmSetWindowAttribute($Window.Handle, 20, [ref]$on, 4)
    } catch { }
}

# The window icon is what sits in the title bar ahead of the caption, in the
# taskbar and in Alt+Tab. Missing or unreadable, the default is used and the
# launcher still starts.
$appIconPath = Join-Path $PSScriptRoot 'icons\agent-launcher.ico'
$script:appIcon = $null
if (Test-Path -LiteralPath $appIconPath -PathType Leaf) {
    try { $script:appIcon = New-Object System.Drawing.Icon $appIconPath } catch { $script:appIcon = $null }
}

function Set-WindowIcon {
    param($Window)
    if ($script:appIcon) { $Window.Icon = $script:appIcon }
}

try { [void][Launcher.AppIdentity]::Set('VirtualRainbow.AgentProjectLauncher') } catch { }

$form = New-Object Launcher.VerticalResizeForm
$form.Text            = 'Start an agent session'
$form.StartPosition   = 'CenterScreen'
$form.FormBorderStyle = 'Sizable'
$form.MaximizeBox     = $false
$form.MinimizeBox     = $true
$form.ClientSize      = New-Object System.Drawing.Size(1020, 504)
$form.MinimumSize     = $form.Size
$form.MaximumSize     = New-Object System.Drawing.Size([System.Windows.Forms.SystemInformation]::MaxWindowTrackSize.Width, [System.Windows.Forms.SystemInformation]::MaxWindowTrackSize.Height)
$form.Font            = $fontBase
$form.BackColor       = $theme.Bg
$form.ForeColor       = $theme.Head
$form.Opacity         = 0
$form.Add_HandleCreated({ Set-DarkTitleBar $form })
Set-WindowIcon $form

# Rows are 30px on a 22px text box, so a label sits 4px down from the control
# it names and everything lands on the same baseline.
$rowStep = 30

function New-ThemeText {
    param(
        $Parent, [string]$Text, [int]$X, [int]$Y,
        [System.Drawing.Color]$Color,
        [int]$Width = 0,
        [System.Drawing.Font]$Font = $null
    )
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.ForeColor = $Color
    $label.BackColor = [System.Drawing.Color]::Transparent
    $label.TextAlign = 'MiddleLeft'
    $label.AutoSize = $false
    $label.AutoEllipsis = $true
    if ($Font) { $label.Font = $Font }
    $label.Location = New-Object System.Drawing.Point($X, $Y)
    $useWidth = if ($Width -gt 0) { $Width } else { 200 }
    $label.Size = New-Object System.Drawing.Size($useWidth, 22)
    $Parent.Controls.Add($label)
    return $label
}

function New-RainbowWordmark {
    param($Parent, [int]$X, [int]$Y)

    $logo = New-Object Launcher.BufferedPanel
    $logo.Location = New-Object System.Drawing.Point($X, $Y)
    $logo.BackColor = $theme.Bg
    $logo.Cursor = [System.Windows.Forms.Cursors]::Hand
    $logo.AccessibleName = 'Virtual Rainbow website'
    $logo.AccessibleDescription = 'Open virtualrainbow.xyz in the default browser'
    $logo.AccessibleRole = [System.Windows.Forms.AccessibleRole]::Link
    $logoFont = New-Object System.Drawing.Font($monoName, 10, [System.Drawing.FontStyle]::Bold)
    # Match the control to the actual glyph run. This keeps the visible text
    # flush with the panel edge and prevents empty space to its right from
    # behaving like part of the link.
    $measureBitmap = New-Object System.Drawing.Bitmap(1, 1)
    $measureGraphics = [System.Drawing.Graphics]::FromImage($measureBitmap)
    $measureFormat = [System.Drawing.StringFormat]::GenericTypographic.Clone()
    [single]$logoWidth = 0
    try {
        foreach ($character in 'VIRTUAL RAINBOW'.ToCharArray()) {
            $measuredCharacter = if ($character -eq ' ') { 'M' } else { [string]$character }
            $logoWidth += $measureGraphics.MeasureString($measuredCharacter, $logoFont, [System.Drawing.PointF]::Empty, $measureFormat).Width
        }
    } finally {
        $measureFormat.Dispose()
        $measureGraphics.Dispose()
        $measureBitmap.Dispose()
    }
    $logo.Size = New-Object System.Drawing.Size(([int][Math]::Ceiling($logoWidth) + 1), 27)
    $logo.Tag = [pscustomobject]@{
        Text = 'VIRTUAL RAINBOW'
        Url = 'https://virtualrainbow.xyz'
        Font = $logoFont
        Colors = @(
            [System.Drawing.Color]::FromArgb(255, 79, 163),
            [System.Drawing.Color]::FromArgb(232, 73, 190),
            [System.Drawing.Color]::FromArgb(196, 78, 225),
            [System.Drawing.Color]::FromArgb(139, 92, 246),
            [System.Drawing.Color]::FromArgb(91, 110, 246),
            [System.Drawing.Color]::FromArgb(59, 130, 246),
            [System.Drawing.Color]::FromArgb(34, 180, 238),
            [System.Drawing.Color]::FromArgb(34, 211, 238),
            [System.Drawing.Color]::FromArgb(45, 211, 178),
            [System.Drawing.Color]::FromArgb(52, 211, 153),
            [System.Drawing.Color]::FromArgb(132, 204, 22),
            [System.Drawing.Color]::FromArgb(250, 204, 21),
            [System.Drawing.Color]::FromArgb(251, 174, 44),
            [System.Drawing.Color]::FromArgb(251, 146, 60),
            [System.Drawing.Color]::FromArgb(244, 114, 106)
        )
    }
    $logo.Add_Paint({
        $state = $this.Tag
        $_.Graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
        $format = [System.Drawing.StringFormat]::GenericTypographic.Clone()
        try {
            $widths = @()
            [single]$textWidth = 0
            foreach ($character in $state.Text.ToCharArray()) {
                $measureCharacter = if ($character -eq ' ') { 'M' } else { [string]$character }
                $glyphWidth = $_.Graphics.MeasureString($measureCharacter, $state.Font, [System.Drawing.PointF]::Empty, $format).Width
                $widths += $glyphWidth
                $textWidth += $glyphWidth
            }
            [single]$drawX = 0
            for ($index = 0; $index -lt $state.Text.Length; $index++) {
                $character = [string]$state.Text[$index]
                if ($character -ne ' ') {
                    $brush = New-Object System.Drawing.SolidBrush($state.Colors[$index])
                    try { $_.Graphics.DrawString($character, $state.Font, $brush, $drawX, 3, $format) }
                    finally { $brush.Dispose() }
                }
                $drawX += $widths[$index]
            }
        } finally {
            $format.Dispose()
        }
    })
    $logo.Add_Disposed({
        if ($this.Tag -and $this.Tag.Font) { $this.Tag.Font.Dispose() }
    })
    $logo.Add_Click({
        try { Start-Process -FilePath ([string]$this.Tag.Url) }
        catch {
            [void][System.Windows.Forms.MessageBox]::Show(
                $form,
                'Could not open virtualrainbow.xyz in the default browser.',
                'Could not open website'
            )
        }
    })
    $Parent.Controls.Add($logo)
    return $logo
}

# Buttons are typed, not clicked-looking: the brackets are the affordance, so
# the chrome is only a border on the two that end the session-building.
function New-ThemeButton {
    param(
        $Parent, [string]$Text, [int]$X, [int]$Y, [int]$Width,
        [System.Drawing.Color]$Color,
        [int]$BorderSize = 0
    )
    $button = New-Object System.Windows.Forms.Button
    $button.Text = '[ {0} ]' -f $Text
    $button.Location = New-Object System.Drawing.Point($X, $Y)
    $button.Size = New-Object System.Drawing.Size($Width, 26)
    $button.FlatStyle = 'Flat'
    $button.BackColor = $theme.Panel
    $button.ForeColor = $Color
    $button.FlatAppearance.BorderSize = $BorderSize
    $button.FlatAppearance.BorderColor = $Color
    $button.FlatAppearance.MouseOverBackColor = $theme.Field
    $button.FlatAppearance.MouseDownBackColor = $theme.Border
    $Parent.Controls.Add($button)
    return $button
}

# A disabled WinForms button ignores ForeColor and uses a nearly black system
# colour in this dark theme. Keep selected buttons enabled for painting, record
# whether their action is available in Tag, and let the click handler no-op.
function Set-ThemeButtonAvailable {
    param($Button, [bool]$Available)
    $Button.Enabled = $true
    $Button.Tag = $Available
    $ink = if ($Available) { $theme.Head } else { $theme.Label }
    $Button.ForeColor = $ink
    $Button.FlatAppearance.BorderColor = $ink
}

# A ComboBox paints its own white edge and a system dropdown button, and neither
# honours BackColor. So the real control is oversized inside a clipping panel
# until every system-drawn edge falls outside the visible box, the items are
# owner-drawn in theme colours, and the arrow beside them is a label we own.
function New-ThemeCombo {
    param($Parent, [int]$X, [int]$Y, [int]$Width)

    $outer = New-Object Launcher.BufferedPanel
    $outer.Location = New-Object System.Drawing.Point($X, $Y)
    $outer.Size = New-Object System.Drawing.Size($Width, 26)
    $outer.BackColor = $theme.Field
    $outer.Add_Paint({
        $pen = New-Object System.Drawing.Pen $theme.Border
        $_.Graphics.DrawRectangle($pen, 0, 0, ($this.Width - 1), ($this.Height - 1))
        $pen.Dispose()
    })
    $Parent.Controls.Add($outer)

    $clip = New-Object Launcher.BufferedPanel
    $clip.Location = New-Object System.Drawing.Point(1, 1)
    $clip.Size = New-Object System.Drawing.Size(($Width - 2), 24)
    $clip.BackColor = $theme.Field
    $outer.Controls.Add($clip)

    $combo = New-Object System.Windows.Forms.ComboBox
    $combo.DropDownStyle = 'DropDownList'
    $combo.FlatStyle = 'Flat'
    $combo.DrawMode = 'OwnerDrawFixed'
    $combo.ItemHeight = 20
    $combo.BackColor = $theme.Field
    $combo.ForeColor = $theme.Value
    $combo.Location = New-Object System.Drawing.Point(-1, -1)
    $combo.Size = New-Object System.Drawing.Size(($Width + 22), 26)
    # The caller only ever holds the combo, so it carries the box it lives in:
    # hiding the widget means hiding the outer panel, not the control.
    $combo.Tag = $outer
    $combo.Add_DrawItem({
        $back = if ($_.State -band [System.Windows.Forms.DrawItemState]::Selected) { $theme.Border } else { $theme.Field }
        $brush = New-Object System.Drawing.SolidBrush $back
        $_.Graphics.FillRectangle($brush, $_.Bounds)
        $brush.Dispose()
        if ($_.Index -lt 0) { return }
        $ink = if ($this.Enabled) { $theme.Value } else { $theme.Muted }
        $textBrush = New-Object System.Drawing.SolidBrush $ink
        $_.Graphics.DrawString([string]$this.Items[$_.Index], $this.Font, $textBrush, ($_.Bounds.Left + 1), ($_.Bounds.Top + 1))
        $textBrush.Dispose()
    })
    $clip.Controls.Add($combo)

    $arrow = New-Object System.Windows.Forms.Label
    $arrow.Text = [string][char]0x25BE
    $arrow.ForeColor = $theme.Label
    $arrow.BackColor = $theme.Field
    $arrow.TextAlign = 'MiddleCenter'
    $arrow.Location = New-Object System.Drawing.Point(($Width - 22), 0)
    $arrow.Size = New-Object System.Drawing.Size(20, 24)
    $arrow.Tag = $combo
    # The label covers the only part of the combo the mouse would otherwise hit
    # there, so it has to open the list itself.
    $arrow.Add_Click({ if ($this.Tag.Enabled) { $this.Tag.DroppedDown = $true } })
    $clip.Controls.Add($arrow)
    $arrow.BringToFront()

    # A disabled combo fills its client in the system's grey and leaves a light
    # frame around the owner-drawn item, which no inset escapes. These strips sit
    # in the field colour on that frame: invisible while enabled, and the reason
    # a disabled row still looks like the rest of the window.
    foreach ($edge in @(
        @(0, 0, ($Width - 2), 2),
        @(0, 22, ($Width - 2), 2),
        @(0, 0, 2, 24),
        @(($Width - 4), 0, 2, 24)
    )) {
        $mask = New-Object Launcher.BufferedPanel
        $mask.BackColor = $theme.Field
        $mask.Location = New-Object System.Drawing.Point $edge[0], $edge[1]
        $mask.Size = New-Object System.Drawing.Size $edge[2], $edge[3]
        $clip.Controls.Add($mask)
        $mask.BringToFront()
    }

    return $combo
}

# Same idea for a text box: the control draws no border at all, and the panel
# behind it draws the one the theme wants.
function New-ThemeTextBox {
    param($Parent, [int]$X, [int]$Y, [int]$Width)
    $outer = New-Object Launcher.BufferedPanel
    $outer.Location = New-Object System.Drawing.Point($X, $Y)
    $outer.Size = New-Object System.Drawing.Size($Width, 26)
    $outer.BackColor = $theme.Field
    $outer.Add_Paint({
        $pen = New-Object System.Drawing.Pen $theme.Border
        $_.Graphics.DrawRectangle($pen, 0, 0, ($this.Width - 1), ($this.Height - 1))
        $pen.Dispose()
    })
    $Parent.Controls.Add($outer)

    $box = New-Object System.Windows.Forms.TextBox
    $box.BorderStyle = 'None'
    $box.BackColor = $theme.Field
    $box.ForeColor = $theme.Value
    $box.Location = New-Object System.Drawing.Point(5, 4)
    $box.Size = New-Object System.Drawing.Size(($Width - 10), 18)
    $outer.Controls.Add($box)
    return $box
}

# A bordered box the panels are drawn as. BorderStyle would paint it in a system
# colour, which is the one thing the theme cannot override.
function New-ThemePanel {
    param($Parent, [int]$X, [int]$Y, [int]$Width, [int]$Height, [switch]$Bordered)
    $panel = New-Object Launcher.BufferedPanel
    $panel.Location = New-Object System.Drawing.Point($X, $Y)
    $panel.Size = New-Object System.Drawing.Size($Width, $Height)
    $panel.BackColor = $theme.Panel
    if ($Bordered) {
        $panel.Add_Paint({
            $pen = New-Object System.Drawing.Pen $theme.Border
            $rect = New-Object System.Drawing.Rectangle 0, 0, ($this.Width - 1), ($this.Height - 1)
            $_.Graphics.DrawRectangle($pen, $rect)
            $pen.Dispose()
        })
    }
    $Parent.Controls.Add($panel)
    return $panel
}

# Directory.Exists with a deadline. A dead network drive or share can block a
# plain check for 40+ seconds; here it is given 1.5s and then treated as absent.
if (-not ('Launcher.QuickPath' -as [type])) {
    Add-Type -TypeDefinition @'
using System.IO;
using System.Threading.Tasks;
namespace Launcher {
    public static class QuickPath {
        public static bool DirectoryExists(string path, int ms) {
            var t = Task.Run(() => { try { return Directory.Exists(path); } catch { return false; } });
            return t.Wait(ms) && t.Result;
        }
    }
}
'@
}
function Test-DirectoryQuick {
    param([string]$Path)
    return [Launcher.QuickPath]::DirectoryExists($Path, 1500)
}

# Returning an array from a function unrolls it, so an empty result arrives as
# $null and $null.Count throws under StrictMode. Every caller wraps in @().
function Get-PickerSubdirectories {
    param([string]$Path)
    try {
        # .NET enumeration: Get-ChildItem is far slower on big folders, Google
        # Drive and network shares, and this runs on the UI thread.
        $hidden = [System.IO.FileAttributes]::Hidden
        $found = New-Object System.Collections.Generic.List[object]
        foreach ($dir in ([System.IO.DirectoryInfo]$Path).EnumerateDirectories()) {
            if ($dir.Name.StartsWith('.') -or ($dir.Attributes -band $hidden)) { continue }
            $found.Add($dir)
        }
        return @($found | Sort-Object Name)
    } catch {
        return @()
    }
}

# Every ready fixed/removable drive, so a picker can reach the whole machine.
# Labelled with the volume name because 'C:\' alone says nothing about which
# disk it is once a Google Drive letter is in the same list.
# '\\host\share' out of any path on that share. Anything shorter is not a
# reachable folder, so a bare '\\host' is not offered.
function Get-UncShareRoot {
    param([string]$Path)
    if (-not $Path -or -not $Path.StartsWith('\\')) { return '' }
    $segments = @($Path.TrimStart('\') -split '\\' | Where-Object { $_ })
    if ($segments.Count -lt 2) { return '' }
    return '\\{0}\{1}' -f $segments[0], $segments[1]
}

# Shares the launcher already knows about: every work folder and scope folder
# ever saved, plus wherever the picker was pointed at when it opened.
function Get-KnownShareRoots {
    param([string]$Extra = '')
    $seen = @()
    $sources = @($script:savedProjects) + @($Extra)
    foreach ($map in @($script:projectContexts)) {
        if ($map) { foreach ($key in @($map.Keys)) { $sources += @($map[$key]) } }
    }
    foreach ($candidate in $sources) {
        $share = Get-UncShareRoot ([string]$candidate)
        if (-not $share) { continue }
        if ($seen -contains $share) { continue }
        $reachable = $false
        $reachable = Test-DirectoryQuick $share
        if ($reachable) { $seen += $share }
    }
    return @($seen)
}

function Get-PickerDriveRoots {
    $roots = @()
    foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
        # IsReady on a disconnected network drive blocks for ~40 seconds, which
        # froze the whole window each time a picker opened.
        if (-not (Test-DirectoryQuick $drive.RootDirectory.FullName)) { continue }
        if ($drive.DriveType -notin @([System.IO.DriveType]::Fixed, [System.IO.DriveType]::Removable, [System.IO.DriveType]::Network)) { continue }
        $label = if ($drive.VolumeLabel) { '{0}  ({1})' -f $drive.Name, $drive.VolumeLabel } else { $drive.Name }
        $roots += [pscustomobject]@{ Path = $drive.RootDirectory.FullName; Label = $label }
    }
    return @($roots)
}

function Add-PickerNode {
    param($Collection, [string]$Text, [string]$Path)
    $node = New-Object System.Windows.Forms.TreeNode $Text
    $node.Tag = $Path
    # A placeholder child is what draws the expander arrow; it is replaced with
    # the real contents the first time the node is opened. It is added without
    # looking inside: probing every child up front walked each subfolder (and
    # every drive) on the UI thread, which froze the window. A folder with no
    # subfolders just loses its arrow when it is opened.
    [void]$node.Nodes.Add((New-Object System.Windows.Forms.TreeNode '...'))
    [void]$Collection.Add($node)
}

# Swaps the '...' placeholder for the real subfolders. BeforeExpand calls this
# when the user opens a node, and the -Initial walk calls it directly: before
# the tree has a window handle, Expand() does not raise BeforeExpand, so the
# walk used to stop at the root and preselect the wrong folder.
function Add-PickerChildNodes {
    param($Node)
    if ($Node.Nodes.Count -ne 1 -or $Node.Nodes[0].Text -ne '...') { return }
    $Node.Nodes.Clear()
    foreach ($child in @(Get-PickerSubdirectories ([string]$Node.Tag))) {
        Add-PickerNode $Node.Nodes $child.Name $child.FullName
    }
}

# Only ever shows the roots it is given, so nothing can be picked that would
# then be refused. -AllowAnywhere lifts that: the given roots stay on top as
# shortcuts, every drive is added below them, and the path box becomes typable
# so a folder can be pasted instead of clicked down to.
function Show-FolderPicker {
    param(
        [Parameter(Mandatory)][string[]]$Roots,
        [string]$Title = 'Choose a folder',
        [string]$Initial = '',
        [switch]$AllowAnywhere
    )
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = $Title
    $dialog.StartPosition = 'CenterParent'
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.ClientSize = New-Object System.Drawing.Size(500, 452)
    $dialog.Font = $fontBase
    $dialog.BackColor = $theme.Bg
    $dialog.ForeColor = $theme.Head
    $dialog.Add_HandleCreated({ Set-DarkTitleBar $dialog })
    Set-WindowIcon $dialog

    [void](New-ThemeText $dialog ('> ' + $Title) 16 12 $theme.Head 460 $fontHead)

    $tree = New-Object System.Windows.Forms.TreeView
    $tree.Location = New-Object System.Drawing.Point(16, 44)
    $tree.Size = New-Object System.Drawing.Size(468, 296)
    $tree.HideSelection = $false
    $tree.BorderStyle = 'FixedSingle'
    $tree.BackColor = $theme.Panel
    $tree.ForeColor = $theme.Value
    $tree.LineColor = $theme.Border
    $dialog.Controls.Add($tree)

    # A share is not a drive, so it can never appear in the tree on its own. The
    # box below is the way in, and unlabelled it reads as a display of what was
    # clicked rather than something to type in.
    $boxHint = if ($AllowAnywhere) {
        'Folder  -  pick above, or type e.g. \\server\share'
    } else { 'Folder' }
    [void](New-ThemeText $dialog $boxHint 16 348 $theme.Label 468)

    # Read-only unless anywhere is allowed, so a typed path cannot slip past the
    # roots in the pickers that are deliberately fenced.
    $chosenBox = New-Object System.Windows.Forms.TextBox
    $chosenBox.Location = New-Object System.Drawing.Point(16, 372)
    $chosenBox.Size = New-Object System.Drawing.Size(468, 24)
    $chosenBox.ReadOnly = -not $AllowAnywhere
    $chosenBox.BorderStyle = 'FixedSingle'
    $chosenBox.BackColor = $theme.Field
    $chosenBox.ForeColor = $theme.Value
    if ($chosenBox.ReadOnly) {
        $chosenBox.BorderStyle = 'None'
        $chosenBox.BackColor = $theme.Bg
        $chosenBox.ForeColor = $theme.Muted
    }
    $dialog.Controls.Add($chosenBox)

    $cancelButton = New-ThemeButton $dialog 'Cancel' 284 412 96 $theme.Muted 1
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

    $chooseButton = New-ThemeButton $dialog 'Choose' 388 412 96 $theme.Section 1
    $chooseButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $chooseButton.Enabled = $false
    $dialog.AcceptButton = $chooseButton
    $dialog.CancelButton = $cancelButton

    $rootEntries = @()
    foreach ($root in $Roots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        $resolvedRoot = (Resolve-Path -LiteralPath $root).ProviderPath
        $rootEntries += [pscustomobject]@{ Path = $resolvedRoot; Label = (Split-Path -Leaf $resolvedRoot) }
    }
    if ($AllowAnywhere) {
        foreach ($drive in @(Get-PickerDriveRoots)) {
            if (Test-PathInList $drive.Path @($rootEntries | ForEach-Object { $_.Path })) { continue }
            $rootEntries += $drive
        }
        # A share has no drive letter to be found under, so it would stay
        # invisible however long you browsed. Any share already in use gets its
        # own root here, which is what makes it browsable the second time.
        foreach ($share in @(Get-KnownShareRoots -Extra $Initial)) {
            if (Test-PathInList $share @($rootEntries | ForEach-Object { $_.Path })) { continue }
            $rootEntries += [pscustomobject]@{ Path = $share; Label = $share }
        }
    }
    foreach ($entry in $rootEntries) { Add-PickerNode $tree.Nodes $entry.Label $entry.Path }

    $tree.Add_BeforeExpand({ Add-PickerChildNodes $_.Node })
    $tree.Add_AfterSelect({
        # Writing the box is what enables Choose, for clicked and typed paths alike.
        $chosenBox.Text = [string]$tree.SelectedNode.Tag
    })
    $chosenBox.Add_TextChanged({
        $candidate = $chosenBox.Text.Trim().Trim('"')
        $exists = $false
        # An unfinished path can contain characters Test-Path refuses outright.
        try { $exists = [bool]$candidate -and (Test-Path -LiteralPath $candidate -PathType Container) } catch { $exists = $false }
        $chooseButton.Enabled = $exists
        # Typing a share once puts it in the tree straight away, so the rest of
        # the way down can be clicked instead of spelled out.
        if ($exists -and $AllowAnywhere) {
            $share = Get-UncShareRoot $candidate
            if ($share) {
                $present = $false
                foreach ($rootNode in $tree.Nodes) {
                    if (Test-SamePath ([string]$rootNode.Tag) $share) { $present = $true; break }
                }
                if (-not $present) { Add-PickerNode $tree.Nodes $share $share }
            }
        }
    })
    $tree.Add_NodeMouseDoubleClick({ if ($chooseButton.Enabled) { $chooseButton.PerformClick() } })

    if ($Initial) {
        foreach ($rootNode in $tree.Nodes) {
            $rootPath = [string]$rootNode.Tag
            if (-not $Initial.StartsWith($rootPath, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            $node = $rootNode
            Add-PickerChildNodes $node
            $node.Expand()
            foreach ($segment in @($Initial.Substring($rootPath.Length).Trim('\') -split '\\' | Where-Object { $_ })) {
                $next = $null
                foreach ($candidate in $node.Nodes) { if ($candidate.Text -eq $segment) { $next = $candidate; break } }
                if ($null -eq $next) { break }
                $node = $next
                Add-PickerChildNodes $node
                $node.Expand()
            }
            $tree.SelectedNode = $node
            break
        }
    }
    if ($null -eq $tree.SelectedNode -and $tree.Nodes.Count -gt 0) { $tree.Nodes[0].Expand() }

    if ($dialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return '' }
    $chosen = $chosenBox.Text.Trim().Trim('"')
    if (-not $chosen) { return '' }
    try { return (Resolve-Path -LiteralPath $chosen).ProviderPath } catch { return '' }
}

# A question with more than two answers, in the window's own colours. Returns
# the option that was chosen, or '' if the dialog was dismissed. The last option
# is the way out, so Escape picks it.
function Show-ThemedChoice {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string[]]$Message,
        [Parameter(Mandatory)][string[]]$Options
    )
    $width = 700
    $bodyTop = 48
    $buttonTop = $bodyTop + ($Message.Count * 24) + 20

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = $Title
    $dialog.StartPosition = 'CenterParent'
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.ClientSize = New-Object System.Drawing.Size($width, ($buttonTop + 26 + 20))
    $dialog.Font = $fontBase
    $dialog.BackColor = $theme.Bg
    $dialog.ForeColor = $theme.Head
    $dialog.Add_HandleCreated({ Set-DarkTitleBar $dialog })

    [void](New-ThemeText $dialog ('> ' + $Title) 20 14 $theme.Head ($width - 40) $fontHead)
    $line = 0
    foreach ($paragraph in $Message) {
        [void](New-ThemeText $dialog $paragraph 20 ($bodyTop + $line * 24) $theme.Label ($width - 40))
        $line++
    }

    $script:themedChoice = ''
    $right = $width - 20
    for ($index = $Options.Count - 1; $index -ge 0; $index--) {
        $text = $Options[$index]
        $buttonWidth = ($text.Length + 4) * 9 + 14
        $right -= $buttonWidth
        $ink = if ($index -eq 0) { $theme.Section } else { $theme.Label }
        $button = New-ThemeButton $dialog $text $right $buttonTop $buttonWidth $ink 1
        $button.Tag = $text
        $button.Add_Click({
            $script:themedChoice = [string]$this.Tag
            $this.FindForm().Close()
        })
        if ($index -eq $Options.Count - 1) { $dialog.CancelButton = $button }
        if ($index -eq 0) { $dialog.AcceptButton = $button }
        $right -= 10
    }

    [void]$dialog.ShowDialog($form)
    return $script:themedChoice
}

# ----------------------------------------------------------------- layout ---
# Three sections in one bordered box, each opened by a '#' heading and closed by
# a rule: where the session runs, what runs it, and how it starts. Labels sit
# above their control so a row can hold four of them side by side.

$panelW = 988
$edgeL  = 16
$edgeR  = 972

$uiNewTab  = New-ThemeButton $form 'New session'   16 10 146 $theme.Section 1
$uiLiveTab = New-ThemeButton $form 'Live sessions' 170 10 162 $theme.Label 1
$uiBrandWordmark = New-RainbowWordmark $form 667 10
$uiBrandWordmark.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right

$panel = New-ThemePanel $form 16 46 $panelW 444 -Bordered
$panel.Anchor = [System.Windows.Forms.AnchorStyles]::Top

# Paths and link lists are longer than the row they live on, so the row shows
# what fits and hovering shows the whole thing. Drawn by hand, because a system
# tooltip would arrive in system colours.
$tips = New-Object System.Windows.Forms.ToolTip
$tips.InitialDelay = 300
$tips.ReshowDelay = 100
$tips.AutoPopDelay = 30000
$tips.OwnerDraw = $true
# Use the same wrapped-text renderer for measuring and drawing. The old popup
# measured an unlimited single line and could become wider than the screen; its
# drawing then escaped the visible tooltip box at some DPI settings.
$tipTextFlags = [System.Windows.Forms.TextFormatFlags]::Left -bor
                [System.Windows.Forms.TextFormatFlags]::Top -bor
                [System.Windows.Forms.TextFormatFlags]::WordBreak -bor
                [System.Windows.Forms.TextFormatFlags]::NoPrefix
$tips.Add_Popup({
    $text = $tips.GetToolTip($_.AssociatedControl)
    if (-not $text) { return }
    $workArea = [System.Windows.Forms.Screen]::FromControl($_.AssociatedControl).WorkingArea
    $maxWidth = [Math]::Min(620, [Math]::Max(280, $workArea.Width - 48))
    $proposed = New-Object System.Drawing.Size(($maxWidth - 14), 0)
    $measured = [System.Windows.Forms.TextRenderer]::MeasureText($text, $fontBase, $proposed, $tipTextFlags)
    $width = [Math]::Min($maxWidth, [Math]::Max(260, $measured.Width + 14))
    $height = [Math]::Min(($workArea.Height - 48), ($measured.Height + 10))
    $_.ToolTipSize = New-Object System.Drawing.Size($width, $height)
})
$tips.Add_Draw({
    $back = New-Object System.Drawing.SolidBrush $theme.Field
    $_.Graphics.FillRectangle($back, $_.Bounds)
    $back.Dispose()
    $pen = New-Object System.Drawing.Pen $theme.Border
    $_.Graphics.DrawRectangle($pen, 0, 0, ($_.Bounds.Width - 1), ($_.Bounds.Height - 1))
    $pen.Dispose()
    $textBounds = New-Object System.Drawing.Rectangle(7, 5, ($_.Bounds.Width - 14), ($_.Bounds.Height - 10))
    [System.Windows.Forms.TextRenderer]::DrawText(
        $_.Graphics, $_.ToolTipText, $fontBase, $textBounds, $theme.Head, $tipTextFlags)
})

function Set-RowTip {
    param($Control, [string]$Text)
    $tips.SetToolTip($Control, $Text)
}

# Short guidance for the launch options.
$help = @{
    Permissions = @(
        'How much the session may do without asking.',
        '',
        '  Read-only (plan)  Nothing is written. Reviewing, auditing, planning.',
        '  Ask me            Every write asks first. Use for client work,',
        '                    private data and unfamiliar repositories.',
        '  Accept edits      Writes inside the workspace without asking, asks',
        '                    for anything outside it. The safe middle.',
        '  Auto-approve      No prompts, and writes are not confined to the',
        '                    workspace. Your own repos, where git can undo it.',
        '  Full access       Also drops the sandbox. Throwaway environments only.',
        '',
        'Codex enforces these with a real Windows sandbox. For Claude they are',
        'policy the agent follows, so a shell command could still step outside.'
    ) -join "`r`n"

    Scope = @(
        "Adds a second folder to this session's workspace.",
        '',
        'It does not grant write permission by itself: the permission mode',
        'decides that. Reading is never restricted, so an agent does not need',
        'this to read a folder.',
        '',
        'Use it when:',
        '  a repo and its vault notes should be edited in one session',
        '  Codex must write outside the project, where its sandbox is a wall',
        '  you want the folder treated as part of the job, not a detour',
        '',
        'On Auto-approve it changes nothing you can feel.'
    ) -join "`r`n"

    Effort = @(
        'Reasoning budget. Default passes no flag, so each CLI uses its own',
        'setting. Higher costs time and tokens: worth it for architecture and',
        'hard debugging, wasted on small edits.'
    ) -join "`r`n"

    Start = @(
        'New session starts clean. Continue last resumes the most recent session',
        'in this folder. Pick a session opens the picker.',
        '',
        "Codex's resume takes a session id, so a first message is dropped there."
    ) -join "`r`n"

    Prompt = @(
        'Sent as the first message the moment the session opens.',
        'Leave it empty to land on an empty prompt.'
    ) -join "`r`n"
    Title = @(
        'A name for this session, shown in Live sessions and as the tab name in Herdr.',
        'Leave it empty and the launcher names the session after what it is working on.'
    ) -join "`r`n"

    Persona = @(
        'Claude only. Starts the session as a subagent defined in',
        '.claude/agents/*.md inside the work folder.'
    ) -join "`r`n"

    Web = @(
        'CLI default    leaves internet access to the agent configuration.',
        'Restricted     turns off the internet controls the CLI exposes.',
        '',
        'Codex: disables web search and outbound shell traffic in its',
        'workspace-write sandbox. Full access bypasses the shell sandbox.',
        '',
        'Claude: removes WebFetch and WebSearch. Claude has no separate',
        'network-off flag, so shell commands may still reach the internet.'
    ) -join "`r`n"

    HandoffStatus = @(
        'Who writes the status the next agent starts from.',
        '',
        '  Session writes it  Types a one-line request into the old session and',
        '                     waits for it to write .agent\handoffs\<id>.status.md.',
        '                     Anything typed but unsent there is sent along.',
        '  I write it         A dialog with the same headings, filled in by hand.',
        '',
        'Either way the next agent reads a short status, never the conversation.',
        'A read-only session cannot write a file, so it starts on I write it.'
    ) -join "`r`n"

    HandoffNote = @(
        'Goes into the handoff file under Note from the user: what to do first,',
        'what to leave alone. Optional.'
    ) -join "`r`n"

    VaultLink = @(
        "Writes 'Vault notes: <path>' into the project's AGENTS.md, so any agent",
        'opening this folder knows where its notes live.',
        '',
        'Click again to change or remove an existing link.'
    ) -join "`r`n"
}

function New-ThemeRule {
    param($Parent, [int]$Y)
    $rule = New-Object Launcher.BufferedPanel
    $rule.Location = New-Object System.Drawing.Point($edgeL, $Y)
    $rule.Size = New-Object System.Drawing.Size(($edgeR - $edgeL), 1)
    $rule.BackColor = $theme.Border
    $Parent.Controls.Add($rule)
    return $rule
}

# A label carrying a '[?]' is hoverable help. The text lives in $help so the
# same words are in the window and in the SOP, rather than drifting apart.
function New-ThemeHelpText {
    param($Parent, [string]$Text, [int]$X, [int]$Y, [System.Drawing.Color]$Color, [int]$Width, [string]$Help)
    $label = New-ThemeText $Parent ('{0}  [?]' -f $Text) $X $Y $Color $Width
    Set-RowTip $label $Help
    return $label
}

[void](New-ThemeText $panel '# Work folder' $edgeL 16 $theme.Section 300)

# Everything runs out to the right edge ($edgeR): the buttons are pushed to the
# side and the fields take the room they leave.
$uiProject = New-ThemeCombo $panel $edgeL 44 712
$uiProjectBrowse = New-ThemeButton $panel 'Browse...' 736 44 124 $theme.Head 1
$uiProjectRemove = New-ThemeButton $panel 'Remove'    868 44 104 $theme.Head 1

$uiProjectPath = New-ThemeText $panel '' $edgeL 78 $theme.Muted ($edgeR - $edgeL)

$uiVaultLink = New-ThemeText $panel '' $edgeL 106 $theme.Muted 844
$uiVaultLinkSet = New-ThemeButton $panel 'Link...' 868 104 104 $theme.Head 1
Set-RowTip $uiVaultLinkSet $help.VaultLink

[void](New-ThemeRule $panel 138)
[void](New-ThemeText $panel '# Agent configuration' $edgeL 152 $theme.Section 400)

# Four columns with an 8px gutter, together exactly as wide as the rules.
[void](New-ThemeText $panel 'Agent' $edgeL 180 $theme.Label 200)
$uiAgent = New-ThemeCombo $panel $edgeL 202 200
[void]$uiAgent.Items.Add('Claude')
[void]$uiAgent.Items.Add('Codex')
$uiAgent.SelectedIndex = 0

# A real dropdown list, so clicking anywhere in the box opens it. Typing a model
# the list does not have is still possible via the 'Other...' entry.
[void](New-ThemeText $panel 'Model' 224 180 $theme.Label 240)
$uiModel = New-ThemeCombo $panel 224 202 240

# The '[?]' marks belong to Advanced options; out here the rows are self
# explanatory, so they carry the hover text without the clutter.
$uiEffortLabel = New-ThemeText $panel 'Effort' 472 180 $theme.Label 200
Set-RowTip $uiEffortLabel $help.Effort
$uiEffort = New-ThemeCombo $panel 472 202 200
Set-RowTip $uiEffort $help.Effort

$uiModeLabel = New-ThemeText $panel 'Permissions' 680 180 $theme.Label 292
Set-RowTip $uiModeLabel $help.Permissions
$uiMode = New-ThemeCombo $panel 680 202 292
foreach ($choice in $modeChoices) { [void]$uiMode.Items.Add($choice) }
$uiMode.SelectedItem = $modeDefaultLabel
Set-RowTip $uiMode $help.Permissions

[void](New-ThemeRule $panel 240)
# One row of four, as wide as the rules: role, terminal, start and the first
# message. Handoff mode reuses the last two slots (see Enter-HandoffMode).
$uiSessionHeading = New-ThemeText $panel '# Session' $edgeL 254 $theme.Section 180
$uiRoleNote = New-ThemeText $panel '' 196 254 $theme.Muted 776
$uiRoleNote.Visible = $false
$uiRoleLabel = New-ThemeText $panel 'Role' $edgeL 282 $theme.Label 140
$uiSessionRole = New-ThemeCombo $panel $edgeL 304 140
[void]$uiSessionRole.Items.Add('Ordinary')
[void]$uiSessionRole.Items.Add('Orchestrator')
$uiSessionRole.SelectedIndex = 0
Set-RowTip $uiRoleLabel 'Ordinary opens the selected CLI normally. Orchestrator delegates project work and runs its managed checks and repairs.'
Set-RowTip $uiSessionRole 'Ordinary opens the selected CLI normally. Orchestrator delegates project work and runs its managed checks and repairs.'
[void](New-ThemeText $panel 'Terminal' 164 282 $theme.Label 120)
$uiTerminalHost = New-ThemeCombo $panel 164 304 120
[void]$uiTerminalHost.Items.Add('Terminal')
[void]$uiTerminalHost.Items.Add('Herdr')
$uiTerminalHost.SelectedItem = $TerminalHost
Set-RowTip $uiTerminalHost 'Herdr adds projects as Spaces in the same persistent Herdr tab. If the tab is closed, the next launch reopens the shared session. Works with Ordinary or Orchestrator.'
$uiTerminalHost.Add_SelectedIndexChanged({
    $script:launchTerminalHost = [string]$uiTerminalHost.SelectedItem
    Save-LauncherSettings
})

$uiStartLabel = New-ThemeText $panel 'Start' 292 282 $theme.Label 150
Set-RowTip $uiStartLabel $help.Start
$uiStartMode = New-ThemeCombo $panel 292 304 150
foreach ($choice in $startChoices) { [void]$uiStartMode.Items.Add($choice) }
$uiStartMode.SelectedItem = $startNewLabel

# Left empty, the agent's own title is used. Not offered for Orchestrator or
# handoff sessions (see Update-Details).
$uiTitleLabel = New-ThemeText $panel 'Title (optional)' 450 282 $theme.Label 190
Set-RowTip $uiTitleLabel $help.Title
$uiSessionTitle = New-ThemeTextBox $panel 450 304 190
$uiSessionTitle.MaxLength = 80
Set-RowTip $uiSessionTitle $help.Title

$uiPromptLabel = New-ThemeText $panel '' 650 282 $theme.Label 322
Set-RowTip $uiPromptLabel $help.Prompt
$uiPrompt = New-ThemeTextBox $panel 650 304 322

# Handoff mode borrows this section: status, timing and an optional note remain
# visible before the action button. The bottom Cancel button exits this mode.
$uiHandoffStatus = New-ThemeCombo $panel 292 304 190
foreach ($choice in $handoffStatusChoices) { [void]$uiHandoffStatus.Items.Add($choice) }
$uiHandoffStatus.SelectedIndex = 0
$uiHandoffStatus.Tag.Visible = $false
Set-RowTip $uiHandoffStatus $help.HandoffStatus
$uiHandoffTimingLabel = New-ThemeText $panel 'When?' 490 282 $theme.Label 270
$uiHandoffTimingLabel.Visible = $false
$uiHandoffTiming = New-ThemeCombo $panel 490 304 270
foreach ($choice in @('Hand off now', 'Checkpoint at next safe point', 'Automatic at 85% account use')) {
    [void]$uiHandoffTiming.Items.Add($choice)
}
$uiHandoffTiming.SelectedIndex = 1
$uiHandoffTiming.Tag.Visible = $false
Set-RowTip $uiHandoffTiming 'Choose when the current session should hand over. Automatic needs a fresh account-limit measurement and the launcher must stay open.'
$script:handoffSource = $null
$script:handoffWorkspace = ''
$script:handoffSavedPrompt = ''
$script:handoffWait = $null

# ------------------------------------------------------- advanced options ---
# Everything here is set once for a project and then left alone, so it stays
# folded away. The disclosure is the only thing that resizes the window now.

$uiAdvancedToggle = New-ThemeText $panel ('{0} Advanced options' -f [char]0x25B8) $edgeL 342 $theme.Label 300
$uiAdvancedToggle.Cursor = [System.Windows.Forms.Cursors]::Hand

$advanced = New-ThemePanel $panel 1 370 ($panelW - 2) 158
$advanced.Visible = $false

# Scope comes first because it changes what the whole session can work on.
[void](New-ThemeHelpText $advanced 'Also in scope' 15 4 $theme.Label 400 $help.Scope)
$uiContext = New-ThemeCombo $advanced 15 30 706
$uiContextAdd = New-ThemeButton $advanced '+ Folder' 729 30 130 $theme.Head 1
Set-RowTip $uiContextAdd $help.Scope
$uiContextRemove = New-ThemeButton $advanced 'Remove' 867 30 104 $theme.Head 1
$uiContextPath = New-ThemeText $advanced '' 15 62 $theme.Muted ($edgeR - $edgeL)

$uiPersonaLabel = New-ThemeHelpText $advanced 'Subagent persona' 15 90 $theme.Label 260 $help.Persona
$uiPersona = New-ThemeCombo $advanced 15 112 240

[void](New-ThemeHelpText $advanced 'Internet access' 290 90 $theme.Label 260 $help.Web)
$uiWeb = New-ThemeCombo $advanced 290 112 200
foreach ($choice in $webChoices) { [void]$uiWeb.Items.Add($choice) }
$uiWeb.SelectedItem = $webDefaultLabel
Set-RowTip $uiWeb $help.Web

# ---------------------------------------------------------- live sessions ---

$livePanel = New-ThemePanel $form 16 46 $panelW 392 -Bordered
$livePanel.Visible = $false
$livePanel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$script:liveColumnKeys = @('Agent', 'Project', 'Model', 'Effort', 'Context', 'Permission')
$script:liveColumnFractions = [ordered]@{ Agent = 0.08; Project = 0.42; Model = 0.13; Effort = 0.08; Context = 0.14; Permission = 0.15 }
$script:liveColumnWidths = @{}
$script:liveResizeStart = $null
$script:liveSplitters = @()
$script:liveLayoutPath = Get-LauncherDataPath 'live-layout.json'
if (Test-Path -LiteralPath $script:liveLayoutPath -PathType Leaf) {
    try {
        $savedLayout = Get-Content -LiteralPath $script:liveLayoutPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($key in $script:liveColumnKeys) {
            $value = $savedLayout.PSObject.Properties[$key]
            if ($value -and [double]$value.Value -gt 0) { $script:liveColumnFractions[$key] = [double]$value.Value }
        }
        $savedTitleWidth = $savedLayout.PSObject.Properties['Title']
        $savedProjectWidth = $savedLayout.PSObject.Properties['Project']
        if ($savedTitleWidth -and $savedProjectWidth) {
            $script:liveColumnFractions.Project = [double]$savedTitleWidth.Value + [double]$savedProjectWidth.Value
        }
        $fractionTotal = 0.0
        foreach ($key in $script:liveColumnKeys) { $fractionTotal += [double]$script:liveColumnFractions[$key] }
        if ($fractionTotal -gt 0) { foreach ($key in $script:liveColumnKeys) { $script:liveColumnFractions[$key] = [double]$script:liveColumnFractions[$key] / $fractionTotal } }
    } catch { }
}
[void](New-ThemeText $livePanel '# Live terminal sessions' $edgeL 16 $theme.Section 400)
$uiLiveCompact = New-ThemeButton $livePanel 'Compact all' 694 12 146 $theme.Head 1
$uiLiveCompact.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
Set-RowTip $uiLiveCompact (@(
    'Types /compact into every session in the list, one at a time.',
    '',
    'There is no other way in: both CLIs are terminal programs, so the launcher',
    'brings each tab to the front and sends the keystrokes. Leave the mouse and',
    'keyboard alone while it runs.',
    '',
    'A session whose tab cannot be identified with certainty is skipped rather',
    'than guessed at, and named in the summary.'
) -join "`r`n")
$uiLiveRefresh = New-ThemeButton $livePanel 'Refresh' 848 12 124 $theme.Head 1
$uiLiveRefresh.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
# Account limits belong to the account, not to a session, so they are shown once
# here instead of repeating on every row. Hover either for the reset times.
$uiLiveClaudeName = New-ThemeText $livePanel '' $edgeL 34 $theme.Claude 70
$uiLiveClaudeValue = New-ThemeText $livePanel '' ($edgeL + 70) 34 $theme.Value 120
$uiLiveCodexName = New-ThemeText $livePanel '' $edgeL 51 $theme.Section 70
$uiLiveCodexValue = New-ThemeText $livePanel '' ($edgeL + 70) 51 $theme.Value 120

# Context carries its own health: green below 60%, amber from 60%, red from 80%.
# A separate column only restated what the colour already says.
$uiLiveAgentHeader = New-ThemeText $livePanel 'Agent' 16 88 $theme.Label 56
$uiLiveProjectHeader = New-ThemeText $livePanel 'Project' 82 88 $theme.Label 200
$uiLiveProjectHeader.Cursor = [System.Windows.Forms.Cursors]::Hand
$uiLiveProjectHeader.AccessibleName = 'Sort live sessions by project'
$uiLiveProjectHeader.Text = 'Project (sort)'
$uiLiveModelHeader = New-ThemeText $livePanel 'Model' 343 88 $theme.Label 74
$uiLiveEffortHeader = New-ThemeText $livePanel 'Effort' 423 88 $theme.Label 48
$uiLiveContextHeader = New-ThemeText $livePanel 'Context' 477 88 $theme.Label 88
$uiLivePermissionHeader = New-ThemeText $livePanel 'Permissions' 641 88 $theme.Label 100
$uiLiveRule = New-ThemeRule $livePanel 114
$uiLiveRule.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$script:liveSplitters = @()
for ($splitIndex = 0; $splitIndex -lt ($script:liveColumnKeys.Count - 1); $splitIndex++) {
    $splitter = New-Object Launcher.BufferedPanel
    $splitter.Location = New-Object System.Drawing.Point(0, 84)
    $splitter.Size = New-Object System.Drawing.Size(7, 24)
    $splitter.BackColor = $theme.Border
    $splitter.Cursor = [System.Windows.Forms.Cursors]::VSplit
    $splitter.Tag = $splitIndex
    $livePanel.Controls.Add($splitter)
    $script:liveSplitters += $splitter
    Set-RowTip $splitter 'Drag to resize the columns on either side.'
    $splitter.Add_MouseDown({
        param($sender, $e)
        if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
        $index = [int]$sender.Tag
        $sender.Capture = $true
        $script:liveResizeStart = @{
            Index = $index
            X = [System.Windows.Forms.Cursor]::Position.X
            LeftWidth = [int]$script:liveColumnWidths[$script:liveColumnKeys[$index]]
            RightWidth = [int]$script:liveColumnWidths[$script:liveColumnKeys[$index + 1]]
            PairFraction = [double]$script:liveColumnFractions[$script:liveColumnKeys[$index]] + [double]$script:liveColumnFractions[$script:liveColumnKeys[$index + 1]]
        }
    })
    $splitter.Add_MouseMove({
        param($sender, $e)
        if (-not $script:liveResizeStart -or [int]$script:liveResizeStart.Index -ne [int]$sender.Tag) { return }
        $index = [int]$sender.Tag
        $leftKey = $script:liveColumnKeys[$index]
        $rightKey = $script:liveColumnKeys[$index + 1]
        $available = [Math]::Max(1, $uiLiveRows.ClientSize.Width - [System.Windows.Forms.SystemInformation]::VerticalScrollBarWidth - (($script:liveColumnKeys.Count - 1) * 10))
        $delta = [System.Windows.Forms.Cursor]::Position.X - [int]$script:liveResizeStart.X
        $minimumWidths = @{ Agent = 55; Project = 190; Model = 65; Effort = 45; Context = 75; Permission = 90 }
        $minimumLeft = [int]$minimumWidths[$leftKey]
        $minimumRight = [int]$minimumWidths[$rightKey]
        $newLeftWidth = [int]$script:liveResizeStart.LeftWidth + $delta
        $newLeftWidth = [Math]::Max($minimumLeft, [Math]::Min(([int]$script:liveResizeStart.LeftWidth + [int]$script:liveResizeStart.RightWidth - $minimumRight), $newLeftWidth))
        $script:liveColumnFractions[$leftKey] = [double]$newLeftWidth / $available
        $script:liveColumnFractions[$rightKey] = [double]$script:liveResizeStart.PairFraction - [double]$script:liveColumnFractions[$leftKey]
        Update-LiveTableLayout
    })
    $splitter.Add_MouseUp({
        param($sender, $e)
        if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left -or -not $script:liveResizeStart) { return }
        $sender.Capture = $false
        $script:liveResizeStart = $null
        try {
            $layoutDirectory = Split-Path -Parent $script:liveLayoutPath
            if (-not (Test-Path -LiteralPath $layoutDirectory -PathType Container)) { [void](New-Item -ItemType Directory -Path $layoutDirectory -Force) }
            $json = ConvertTo-Json -InputObject $script:liveColumnFractions -Depth 4
            [System.IO.File]::WriteAllText($script:liveLayoutPath, $json, (New-Object System.Text.UTF8Encoding($false)))
        } catch { }
    })
}

$uiLiveRows = New-Object Launcher.BufferedPanel
$uiLiveRows.Location = New-Object System.Drawing.Point(16, 120)
$uiLiveRows.Size = New-Object System.Drawing.Size(956, 224)
$uiLiveRows.BackColor = $theme.Panel
$uiLiveRows.Font = $fontBase
$uiLiveRows.AutoScroll = $true
$uiLiveRows.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$livePanel.Controls.Add($uiLiveRows)
$uiLiveSummary = New-ThemeText $livePanel '' 16 354 $theme.Muted 620
$uiLiveSummary.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left

$script:panelHeightCollapsed = 380
$script:panelHeightExpanded  = $advanced.Top + $advanced.Height + 16
$script:livePanelHeightMin   = $livePanel.Height
$script:advancedOpen = $false

# The button row: 16px below the panel, 26px tall, 36px of air beneath it. With
# a 380px panel that adds up to the 504px the window opens at.
$script:buttonGap    = 16
$script:buttonHeight = 26
$script:buttonPad    = 36

# Keep the action row at a fixed distance below the session panel. The form is
# sized to fit it when the panel changes; later window resizing leaves it put.
function Set-ButtonRow {
    param([int]$PanelTop, [int]$PanelHeight, [int]$MinPanelHeight = 0, [switch]$Exact)
    if ($MinPanelHeight -le 0) { $MinPanelHeight = $PanelHeight }
    $below = $script:buttonGap + $script:buttonHeight + $script:buttonPad
    $required = $PanelTop + $PanelHeight + $below
    # Without a floor that follows the layout, dragging the window shorter
    # slides the buttons up behind the panel instead of stopping. The floor is
    # the panel's smallest useful height, not its current one, or a stretched
    # live list could never be dragged back down.
    $chrome = $form.Height - $form.ClientSize.Height
    $form.MinimumSize = New-Object System.Drawing.Size(
        $form.MinimumSize.Width, ($PanelTop + $MinPanelHeight + $below + $chrome))
    $height = $form.ClientSize.Height
    # Exact for the new-session view, where the panel is a fixed height and any
    # surplus is empty space: folding Advanced options away gives the window its
    # old size back. The live list turns surplus into more visible rows, so
    # there the window is only ever grown to fit.
    if (($Exact -and $height -ne $required) -or ($height -lt $required)) {
        $form.ClientSize = New-Object System.Drawing.Size($form.ClientSize.Width, $required)
    }
    $buttonTop = $form.ClientSize.Height - $script:buttonPad - $script:buttonHeight
    $uiStart.Top = $buttonTop
    $uiCancel.Top = $buttonTop
    $uiHandoffCancel.Top = $buttonTop
}

function Update-Layout {
    if ($script:launcherView -eq 'live') { return }
    $advanced.Visible = $script:advancedOpen
    $mark = if ($script:advancedOpen) { [char]0x25BE } else { [char]0x25B8 }
    $uiAdvancedToggle.Text = '{0} Advanced options' -f $mark

    $panelHeight = if ($script:advancedOpen) { $script:panelHeightExpanded } else { $script:panelHeightCollapsed }
    $panel.Height = $panelHeight
    # Resizing only invalidates the newly exposed strip, so the old border would
    # stay painted across the middle of the panel.
    $panel.Refresh()

    Set-ButtonRow -PanelTop $panel.Top -PanelHeight $panelHeight -Exact
}

$uiStart  = New-ThemeButton $form 'Open terminal' 526 442 170 $theme.Section 1
$uiCancel = New-ThemeButton $form 'Cancel' 704 442 100 $theme.Label 1
$uiHandoffCancel = New-ThemeButton $form 'Cancel handoff' 630 442 174 $theme.Label 1
$uiHandoffCancel.Visible = $false
$uiStart.Anchor = [System.Windows.Forms.AnchorStyles]::Top
$uiCancel.Anchor = [System.Windows.Forms.AnchorStyles]::Top
$uiHandoffCancel.Anchor = [System.Windows.Forms.AnchorStyles]::Top
# The action buttons sit against the panel's right edge, Cancel outermost.
function Set-ActionButtonPositions {
    $right = $panel.Left + $panel.Width
    $outer = if ($script:handoffSource) { $uiHandoffCancel } else { $uiCancel }
    $outer.Left = $right - $outer.Width
    $uiStart.Left = $outer.Left - 8 - $uiStart.Width
}
$uiCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
$form.AcceptButton = $uiStart
$form.CancelButton = $uiCancel
$form.Add_FormClosing({
    if ($script:plannedHandoffs.Count -eq 0) { return }
    $answer = [System.Windows.Forms.MessageBox]::Show($form,
        ('{0} planned handoff(s) are still being watched. Closing the launcher stops automatic monitoring. Close anyway?' -f $script:plannedHandoffs.Count),
        'Planned handoff active', 'YesNo', 'Warning')
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { $_.Cancel = $true }
})
# Opening on a focused dropdown means a stray scroll changes the work folder.
$form.Add_Shown({
    # Build and paint the native child controls once while transparent. This
    # avoids their temporary white system-theme rectangles on the first frame.
    $form.Refresh()
    $form.Opacity = 1
    # Come to the front. PowerShell starts with its console hidden, and WinForms
    # takes that as the show state for the first window it creates: the form is
    # built and made visible but never raised, so it opens behind whatever is
    # on screen. On an empty desktop that goes unnoticed; with anything
    # maximised in front it looks exactly like a launcher that never opened.
    $raised = $false
    try { $raised = [Launcher.WindowFocus]::Activate($form.Handle) } catch { }
    if (-not $raised) {
        # Windows would not hand the foreground over. Topmost is not a state
        # to leave a window in - it would then sit over everything else - so
        # it goes on only long enough to lift this one to the top.
        $form.TopMost = $true
        $form.TopMost = $false
        [void]$form.Activate()
    }
    $uiStart.Focus()
})

$uiAdvancedToggle.Add_Click({
    $script:advancedOpen = -not $script:advancedOpen
    Update-Layout
})

$uiNewTab.Add_Click({ Set-LauncherView 'new' })
$uiLiveTab.Add_Click({ Set-LauncherView 'live' })
$uiLiveRefresh.Add_Click({ Refresh-LiveSessions -RefreshAccountUsage })
$uiLiveCompact.Add_Click({
    if (-not [bool]$uiLiveCompact.Tag) { return }
    Invoke-CompactAllSessions
})
$uiHandoffCancel.Add_Click({
    Exit-HandoffMode
    Set-LauncherView 'live'
})

# ------------------------------------------------------------------ state ---

$loaded = Get-LauncherSettings
$script:hiddenProjects = @($loaded.HiddenProjects)

$script:savedProjects  = @($loaded.SavedProjects)

$script:lastAgent      = [string]$loaded.LastAgent
$script:lastProject    = [string]$loaded.LastProject
$script:lastSessionRole = if ($loaded.LastSessionRole -in @('Ordinary','Orchestrator')) { [string]$loaded.LastSessionRole } else { 'Ordinary' }
$script:suspendSessionPreference = $false
$script:projectContexts = $loaded.ProjectContexts
$script:currentProject  = ''
$script:agentModels     = $loaded.AgentModels
$script:agentModes      = $loaded.AgentModes
$script:projectModes    = $loaded.ProjectModes
$script:projectWeb      = $loaded.ProjectWeb
$script:suspendModelPrompt = $false
$script:lastModelChoice    = ''
$script:currentAgent    = ''

# $projectRows is index-aligned with the project combo; $contextPaths is
# index-aligned with the attached-folders list.
$script:projectRows = @()
$script:contextPaths = @()
$script:suspendAutoPair = $false


function Select-VisibleRows {
    param(
        [AllowEmptyCollection()][object[]]$Candidates,
        [AllowEmptyCollection()][string[]]$Hidden
    )
    $rows = @()
    foreach ($candidate in $Candidates) {
        if (Test-PathInList $candidate.Path $Hidden) { continue }
        if (Test-PathInList $candidate.Path @($rows | ForEach-Object { $_.Path })) { continue }
        $rows += $candidate
    }
    return @($rows)
}

function Build-ProjectRows {
    $candidates = @()
    if (Test-Path -LiteralPath $vaultRoot -PathType Container) {
        $candidates += [pscustomobject]@{ Display = $vaultName; Path = $vaultRoot }
    }

    # Code folders first: that is where commands and edits should run, so when a
    # name exists in both roots the code folder wins the working directory.
    $codeNames = @()
    if (Test-Path -LiteralPath $codeProjectsRoot -PathType Container) {
        foreach ($directory in (Get-ChildItem -LiteralPath $codeProjectsRoot -Directory | Sort-Object Name)) {
            $codeNames += $directory.Name
            $candidates += [pscustomobject]@{ Display = $directory.Name; Path = $directory.FullName }
        }
    }
    if (Test-Path -LiteralPath $projectsRoot -PathType Container) {
        foreach ($directory in (Get-ChildItem -LiteralPath $projectsRoot -Directory | Sort-Object Name)) {
            if ($codeNames -contains $directory.Name) { continue }
            $candidates += [pscustomobject]@{ Display = $directory.Name; Path = $directory.FullName }
        }
    }
    foreach ($saved in $script:savedProjects) {
        if (-not (Test-FolderReachable $saved)) { continue }
        $resolved = (Resolve-Path -LiteralPath $saved).ProviderPath
        $candidates += [pscustomobject]@{ Display = (Split-Path -Leaf $resolved); Path = $resolved }
    }
    $rows = @(Select-VisibleRows -Candidates $candidates -Hidden $script:hiddenProjects)

    # A folder picked from anywhere on the machine can share its name with one
    # under the roots - a share called hurlumhej and a local clone of the same
    # name. Two identical lines in the list would be a coin toss, so a repeated
    # name carries the folder above it.
    $nameCounts = @{}
    foreach ($row in $rows) {
        $key = $row.Display.ToLowerInvariant()
        $nameCounts[$key] = 1 + [int]$nameCounts[$key]
    }
    foreach ($row in $rows) {
        if ($nameCounts[$row.Display.ToLowerInvariant()] -le 1) { continue }
        $parent = Split-Path -Parent $row.Path
        if ($parent) { $row.Display = '{0}  -  {1}' -f $row.Display, $parent }
    }
    return $rows
}

function Get-AttachedContextPaths {
    return @($script:contextPaths)
}

# The combo shows one attached folder at a time; the summary line underneath
# always spells out the full set, so nothing is hidden behind the dropdown.
function Set-AttachedContextPaths {
    param(
        [AllowEmptyCollection()][string[]]$Paths,
        [string]$Select
    )
    $kept = @()
    foreach ($path in $Paths) {
        if (-not $path) { continue }
        if (-not (Test-FolderReachable $path)) { continue }
        $resolved = (Resolve-Path -LiteralPath $path).ProviderPath
        if (-not (Test-PathInList $resolved $kept)) { $kept += $resolved }
    }
    $script:contextPaths = @($kept)
    $uiContext.BeginUpdate()
    $uiContext.Items.Clear()
    foreach ($path in $script:contextPaths) { [void]$uiContext.Items.Add((Get-VaultRelativeLabel $path)) }
    $uiContext.EndUpdate()
    if ($script:contextPaths.Count -eq 0) {
        # Clearing Items leaves the last label painted in the box; reset it too.
        $uiContext.SelectedIndex = -1
        $uiContext.ResetText()
        return
    }
    $target = 0
    for ($index = 0; $index -lt $script:contextPaths.Count; $index++) {
        if (Test-SamePath $script:contextPaths[$index] $Select) { $target = $index; break }
    }
    $uiContext.SelectedIndex = $target
}

# Extra writable folders are remembered per project. An entry that exists but is empty
# is a real answer ("this project takes no context"), not a missing one, so the
# pairing suggestion must not come back and override it.
function Save-ProjectContexts {
    if (-not $script:currentProject) { return }
    $script:projectContexts[$script:currentProject] = @(Get-AttachedContextPaths)
}

# The permission mode is a property of the folder, not of the day: sensitive work should
# open in Ask me however the last session on another project was launched. The
# per-agent mode stays as the fallback for a project that has never set one.
function Save-ProjectMode {
    if (-not $script:currentProject) { return }
    if ($uiMode.SelectedIndex -ge 0) { $script:projectModes[$script:currentProject] = [string]$uiMode.SelectedItem }
    if ($uiWeb.SelectedIndex -ge 0)  { $script:projectWeb[$script:currentProject]   = [string]$uiWeb.SelectedItem }
}

function Load-ProjectMode {
    param([string]$ProjectPath)
    $wanted = ''
    if ($ProjectPath -and $script:projectModes.ContainsKey($ProjectPath)) {
        $wanted = Get-ModeSlug ([string]$script:projectModes[$ProjectPath])
    }
    if (-not $wanted) {
        $agentName = [string]$uiAgent.SelectedItem
        if ($agentName -and $script:agentModes.ContainsKey($agentName)) {
            $wanted = Get-ModeSlug ([string]$script:agentModes[$agentName])
        }
    }
    $uiMode.SelectedItem = if ($modeChoices -contains $wanted) { $wanted } else { $modeDefaultLabel }

    $web = ''
    if ($ProjectPath -and $script:projectWeb.ContainsKey($ProjectPath)) { $web = Get-WebSlug ([string]$script:projectWeb[$ProjectPath]) }
    $uiWeb.SelectedItem = if ($webChoices -contains $web) { $web } else { $webDefaultLabel }
}

function Load-ProjectContexts {
    param([string]$ProjectPath)
    $script:currentProject = [string]$ProjectPath
    if (-not $ProjectPath) { Set-AttachedContextPaths @(); return }
    if ($script:projectContexts.ContainsKey($ProjectPath)) {
        Set-AttachedContextPaths @($script:projectContexts[$ProjectPath])
        return
    }
    # Nothing is attached by default. Both agents can already READ anywhere;
    # --add-dir only grants write, so it has to be a deliberate choice.
    Set-AttachedContextPaths @()
}

function Save-AgentModel {
    if (-not $script:currentAgent) { return }
    if ($uiMode.SelectedIndex -ge 0) { $script:agentModes[$script:currentAgent] = [string]$uiMode.SelectedItem }
    if ($uiModel.SelectedIndex -lt 0) { return }
    # Store the bare model name, so the "(default)" marker can move if the CLI
    # config changes without stranding the remembered choice.
    $script:agentModels[$script:currentAgent] = Get-ModelSlug ([string]$uiModel.SelectedItem)
}

function Set-ModelSelection {
    param([string]$Value)
    $script:suspendModelPrompt = $true
    $wanted = Get-ModelSlug $Value
    for ($index = 0; $index -lt $uiModel.Items.Count; $index++) {
        if ((Get-ModelSlug ([string]$uiModel.Items[$index])) -eq $wanted) {
            $uiModel.SelectedIndex = $index
            $script:suspendModelPrompt = $false
            return
        }
    }
    # A model the list does not know about (typed once, or dropped from the
    # cache) still deserves a slot rather than being silently swapped out.
    [void]$uiModel.Items.Insert([Math]::Max($uiModel.Items.Count - 1, 0), $Value)
    $uiModel.SelectedItem = $Value
    $script:suspendModelPrompt = $false
}

function Load-AgentModel {
    param([string]$AgentName)
    $script:currentAgent = [string]$AgentName
    if (-not $AgentName) { return }
    $script:suspendModelPrompt = $true
    $uiModel.BeginUpdate()
    $uiModel.Items.Clear()
    foreach ($choice in (Get-ModelChoices $AgentName)) { [void]$uiModel.Items.Add($choice) }
    [void]$uiModel.Items.Add($modelOtherLabel)
    $uiModel.EndUpdate()
    $script:suspendModelPrompt = $false
    # The project's own mode outranks the agent's, and falls back to it.
    Load-ProjectMode $script:currentProject
    $remembered = if ($script:agentModels.ContainsKey($AgentName)) { [string]$script:agentModels[$AgentName] } else { '' }
    # Older settings stored a "Default (...)" pseudo-entry; that is a marker, not
    # a model, so fall back to whatever the CLI is configured to use.
    if ($remembered -match '^\s*Default\b') { $remembered = '' }
    # Codex's locally cached list is refreshed by the CLI. A remembered model
    # that has disappeared from it is usually a retired or mistyped model and
    # must not keep breaking every new session.
    if ($AgentName -eq 'Codex' -and $remembered) {
        $available = @(Get-CodexModelSlugs)
        if ($available.Count -gt 0 -and -not ($available -contains $remembered)) {
            $remembered = ''
            [void]$script:agentModels.Remove($AgentName)
        }
    }
    if (-not $remembered) { $remembered = Get-AgentDefaultModel $AgentName }
    # A settings file or CLI config holding a pinned id must not put the version
    # number back into the list it was just taken out of.
    if ($AgentName -eq 'Claude') { $remembered = Get-ClaudeModelAlias $remembered }
    if (-not $remembered) { $remembered = Get-ModelSlug ([string]$uiModel.Items[0]) }
    Set-ModelSelection $remembered
}

function Refresh-EffortChoices {
    $agentName = [string]$uiAgent.SelectedItem
    if (-not $agentName) { return }
    $keep = [string]$uiEffort.SelectedItem
    $uiEffort.BeginUpdate()
    $uiEffort.Items.Clear()
    foreach ($choice in (Get-EffortChoices -Agent $agentName -Model (Get-ModelSlug ([string]$uiModel.SelectedItem)))) {
        [void]$uiEffort.Items.Add($choice)
    }
    $uiEffort.EndUpdate()
    $uiEffort.SelectedItem = if ($keep -and $uiEffort.Items.Contains($keep)) { $keep } else { $effortDefaultLabel }
}

function Refresh-PersonaChoices {
    $keep = [string]$uiPersona.SelectedItem
    $uiPersona.BeginUpdate()
    $uiPersona.Items.Clear()
    foreach ($choice in (Get-PersonaChoices (Get-SelectedProjectPath))) { [void]$uiPersona.Items.Add($choice) }
    $uiPersona.EndUpdate()
    $uiPersona.SelectedItem = if ($keep -and $uiPersona.Items.Contains($keep)) { $keep } else { $personaNoneLabel }
}

function Get-SelectedProjectPath {
    if ($uiProject.SelectedIndex -lt 0) { return $null }
    return $script:projectRows[$uiProject.SelectedIndex].Path
}

$script:liveSessions = @()
$script:liveProjectSortDescending = $null
$script:launcherView = 'new'

function Test-LiveSessionProject {
    param($Session, [string]$ProjectPath)
    if (-not $Session -or -not $ProjectPath) { return $false }
    if ($Session.Workspace) { return (Test-SamePath $Session.Workspace $ProjectPath) }
    return $Session.Project -eq (Split-Path -Leaf $ProjectPath)
}

# Every agent session is a tab inside one Windows Terminal window, so reaching a
# particular session means walking the UI Automation tree. That walk cannot run
# here. The first call into UIAutomationCore makes the calling process
# DPI-aware, and Windows then stops scaling this window for the display. The
# layout is hardcoded pixels written for a DPI-unaware process, so on a scaled
# display the window collapses - at 150% to two thirds of its size - with every
# glyph still drawn full size, and the columns and buttons cut their own text
# off. Nothing takes it back either: a window keeps the awareness it was created
# with. So the tab walk, the focus change and the keystrokes all run in a
# separate PowerShell process, which is free to become DPI-aware because it
# never shows a window.
$script:tabAgentScript = @'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# One word on stdout is the whole protocol. The caller reads the last non-empty
# line, so anything a module or a warning prints on the way cannot be mistaken
# for the answer.
function Write-Status {
    param([string]$Value)
    [Console]::Out.WriteLine($Value)
    exit 0
}

$sessionTitle   = [string]$env:TABAGENT_TITLE
$sessionProject = [string]$env:TABAGENT_PROJECT
$sessionAgent   = [string]$env:TABAGENT_AGENT
$command        = [string]$env:TABAGENT_COMMAND
# How long typed text is given before Enter. A slash command needs a moment for
# its palette; a long line needs longer, or a CLI can take the burst of typing
# for a paste and turn the Enter into a new line.
$settle = 250
if ([string]$env:TABAGENT_SETTLE_MS -match '^\d+$') { $settle = [int]$env:TABAGENT_SETTLE_MS }

try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
    Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
} catch { Write-Status 'failed' }

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class TabFocus {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, IntPtr pid);
    [DllImport("user32.dll")] private static extern bool AttachThreadInput(uint attach, uint attachTo, bool doAttach);
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    private const int SW_RESTORE = 9;
    public static bool Activate(IntPtr hWnd) {
        if (hWnd == IntPtr.Zero) return false;
        if (IsIconic(hWnd)) ShowWindow(hWnd, SW_RESTORE);
        uint self = GetCurrentThreadId();
        uint owner = GetWindowThreadProcessId(GetForegroundWindow(), IntPtr.Zero);
        bool attached = (owner != 0 && owner != self && AttachThreadInput(self, owner, true));
        try { SetForegroundWindow(hWnd); }
        finally { if (attached) AttachThreadInput(self, owner, false); }
        return GetForegroundWindow() == hWnd;
    }
}
"@

# The desktop's tab controls are not only Windows Terminal's: a browser and File
# Explorer expose theirs too, and a Chrome tab is quite capable of being called
# 'HelleK' at the same moment a session is. Anything typed at a wrongly chosen
# tab goes into someone else's window, so only tabs belonging to a terminal host
# process are eligible.
$hostNames = @{}
function Test-TerminalHostWindow {
    param($Element)
    if (-not $Element) { return $false }
    $processId = [int]$Element.Current.ProcessId
    if (-not $hostNames.ContainsKey($processId)) {
        $name = ''
        try { $name = (Get-Process -Id $processId -ErrorAction Stop).ProcessName } catch { }
        $hostNames[$processId] = $name
    }
    return ([string]$hostNames[$processId] -match '(?i)^(WindowsTerminal|OpenConsole|conhost|powershell|pwsh)$')
}

function Get-TabOwnerWindow {
    param($Element)
    $owner = $Element
    while ($owner -and $owner.Current.ControlType -ne [System.Windows.Automation.ControlType]::Window) {
        $owner = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($owner)
    }
    return $owner
}

$ambiguous = $false

function Select-SessionTab {
    $condition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::TabItem
    )
    $tabs = [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants,
        $condition
    )
    # Not $matches: that is PowerShell's automatic capture-group variable, and
    # the -match tests below overwrite it with a hashtable mid-loop.
    $candidates = @()
    for ($index = 0; $index -lt $tabs.Count; $index++) {
        $tab = $tabs.Item($index)
        $name = [string]$tab.Current.Name
        if (-not $name) { continue }
        $owner = Get-TabOwnerWindow $tab
        if (-not $owner) { continue }
        if (-not (Test-TerminalHostWindow $owner)) { continue }

        # The tab has to name this session before anything else counts.
        # Rewarding an agent marker on its own scored every Claude tab the same,
        # and a pile of equal scores reads as "cannot tell them apart".
        $identity = 0
        if ($sessionTitle -and $name.Equals($sessionTitle, [System.StringComparison]::OrdinalIgnoreCase)) {
            $identity += 200
        } elseif ($sessionTitle -and $name.IndexOf($sessionTitle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $identity += 100
        }
        if ($sessionProject -and $name.IndexOf($sessionProject, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $identity += 40
        }
        if ($identity -le 0) { continue }

        # An agent marker now only separates two tabs that both name the
        # session, and the wrong agent's marker rules a tab out.
        $score = $identity
            $looksClaude = ($name -match '(?i)Claude') -or
                ($name -match ('[{0}{1}{2}]' -f [char]0x2733, [char]0x273B, [char]0x2722))
        $looksCodex = ($name -match '(?i)Codex|>_')
        if ($sessionAgent -eq 'Codex') {
            if ($looksCodex) { $score += 300 }
            if ($looksClaude) { $score -= 500 }
        } else {
            if ($looksClaude) { $score += 300 }
            if ($looksCodex) { $score -= 500 }
        }
        if ($score -gt 0) {
            $candidates += [pscustomobject]@{ Element = $tab; Owner = $owner; Score = $score }
        }
    }
    $best = $candidates | Sort-Object Score -Descending | Select-Object -First 1
    if (-not $best) { return [System.IntPtr]::Zero }
    $sameScore = @($candidates | Where-Object { $_.Score -eq $best.Score })
    if ($sameScore.Count -gt 1) {
        # Two indistinguishable tabs are not safe to guess between. New launcher
        # sessions keep a unique marker in a title applications cannot replace.
        $script:ambiguous = $true
        return [System.IntPtr]::Zero
    }

    # Stop at the Windows Terminal window. Walking on through it to the desktop
    # root let the right tab be selected without its terminal ever receiving
    # keyboard focus.
    $owner = $best.Owner
    if (-not $owner) { return [System.IntPtr]::Zero }

    $pattern = $null
    $selected = $false
    if ($best.Element.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$pattern)) {
        ([System.Windows.Automation.SelectionItemPattern]$pattern).Select()
        $selected = $true
    } elseif ($best.Element.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) {
        ([System.Windows.Automation.InvokePattern]$pattern).Invoke()
        $selected = $true
    }
    if (-not $selected) { return [System.IntPtr]::Zero }

    Start-Sleep -Milliseconds 60
    $windowHandle = [System.IntPtr]$owner.Current.NativeWindowHandle
    if ($windowHandle -eq [System.IntPtr]::Zero) { return [System.IntPtr]::Zero }
    [void][TabFocus]::Activate($windowHandle)

    # Selecting a tab does not imply keyboard focus. Find the visible terminal
    # control inside that window and focus it so typing can begin immediately
    # without an extra click.
    $focusCondition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::IsKeyboardFocusableProperty,
        $true
    )
    $focusable = $owner.FindAll([System.Windows.Automation.TreeScope]::Descendants, $focusCondition)
    $focusMatches = @()
    for ($focusIndex = 0; $focusIndex -lt $focusable.Count; $focusIndex++) {
        $element = $focusable.Item($focusIndex)
        if ($element.Current.IsOffscreen -or -not $element.Current.IsEnabled) { continue }
        $type = $element.Current.ControlType
        if ($type -eq [System.Windows.Automation.ControlType]::TabItem -or
            $type -eq [System.Windows.Automation.ControlType]::Button) { continue }

        $focusScore = 0
        $identity = ([string]$element.Current.AutomationId) + ' ' + ([string]$element.Current.ClassName)
        if ($identity -match '(?i)Terminal|TermControl') { $focusScore += 200 }
        if ($type -eq [System.Windows.Automation.ControlType]::Document) { $focusScore += 100 }
        if ($type -eq [System.Windows.Automation.ControlType]::Text) { $focusScore += 80 }
        if ($type -eq [System.Windows.Automation.ControlType]::Pane -or
            $type -eq [System.Windows.Automation.ControlType]::Custom) { $focusScore += 40 }
        if ($focusScore -gt 0) {
            $focusMatches += [pscustomobject]@{ Element = $element; Score = $focusScore }
        }
    }
    $focusTarget = $focusMatches | Sort-Object Score -Descending | Select-Object -First 1
    if ($focusTarget) {
        try { $focusTarget.Element.SetFocus() } catch { }
    }
    return $windowHandle
}

$windowHandle = [System.IntPtr]::Zero
try { $windowHandle = Select-SessionTab } catch { $windowHandle = [System.IntPtr]::Zero }
if ($windowHandle -eq [System.IntPtr]::Zero) {
    if ($ambiguous) { Write-Status 'ambiguous' }
    Write-Status 'notfound'
}
# No command means the caller only wanted the tab brought to the front.
if (-not $command) { Write-Status 'shown' }

[void][TabFocus]::Activate($windowHandle)
# Windows hands the foreground over asynchronously.
$deadline = [datetime]::UtcNow.AddMilliseconds(1500)
while ([datetime]::UtcNow -lt $deadline) {
    if ([TabFocus]::GetForegroundWindow() -eq $windowHandle) { break }
    Start-Sleep -Milliseconds 50
}
if ([TabFocus]::GetForegroundWindow() -ne $windowHandle) { Write-Status 'focus' }

try {
    [System.Windows.Forms.SendKeys]::SendWait($command)
    # The slash-command palette needs a moment to filter down to the typed
    # command before Enter chooses it. Touching the keyboard or the mouse during
    # that pause moves the foreground, and the rest of the keystrokes follow it
    # into whatever window arrived, so check again before pressing Enter and
    # leave the line unsent rather than send it somewhere else.
    Start-Sleep -Milliseconds $settle
    if ([TabFocus]::GetForegroundWindow() -ne $windowHandle) { Write-Status 'moved' }
    [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
    Start-Sleep -Milliseconds 150
} catch {
    Write-Status 'failed'
}
Write-Status 'sent'
'@

$script:tabAgentPath = $null
function Get-TabAgentPath {
    if ($script:tabAgentPath -and (Test-Path -LiteralPath $script:tabAgentPath -PathType Leaf)) {
        return $script:tabAgentPath
    }
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ('agent-launcher-tab-' + [guid]::NewGuid().ToString('N') + '.ps1')
    Set-Content -LiteralPath $path -Value $script:tabAgentScript -Encoding UTF8
    $script:tabAgentPath = $path
    return $path
}

function Remove-TabAgentScript {
    if ($script:tabAgentPath -and (Test-Path -LiteralPath $script:tabAgentPath -PathType Leaf)) {
        try { Remove-Item -LiteralPath $script:tabAgentPath -Force -ErrorAction Stop } catch { }
    }
    $script:tabAgentPath = $null
}

# Returns one of: shown, sent, ambiguous, notfound, focus, moved, failed.
function Invoke-TabAgent {
    param([Parameter(Mandatory)]$Session, [string]$Command = '', [int]$SettleMilliseconds = 250)

    $path = $null
    try { $path = Get-TabAgentPath } catch { return 'failed' }

    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $script:powerShellExe
    # MTA, not STA. A UI Automation client asks other processes for their trees
    # over COM, and on a single-threaded apartment the reply has to come back
    # through a message pump this helper does not have, so the first sweep never
    # returns. On a multi-threaded apartment the call completes on its own.
    $info.Arguments = '-NoProfile -NonInteractive -MTA -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $path
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.CreateNoWindow = $true
    # The session details travel in the environment. A window title is free text
    # and would otherwise have to survive two rounds of command line quoting.
    $info.EnvironmentVariables['TABAGENT_TITLE'] = [string]$Session.WindowTitle
    $info.EnvironmentVariables['TABAGENT_PROJECT'] = [string]$Session.Project
    $info.EnvironmentVariables['TABAGENT_AGENT'] = [string]$Session.Agent
    $info.EnvironmentVariables['TABAGENT_COMMAND'] = $Command
    $info.EnvironmentVariables['TABAGENT_SETTLE_MS'] = [string]$SettleMilliseconds

    $process = $null
    try {
        $process = [System.Diagnostics.Process]::Start($info)
        # Only a process that already owns the foreground may hand it on. The
        # helper has no window of its own, so without this it cannot bring the
        # terminal forward.
        try { [void][Launcher.WindowFocus]::AllowSetForegroundWindow([uint32]$process.Id) } catch { }
        # Read on a task, not inline: a synchronous read of a helper that never
        # answers blocks the launcher's own message loop, and the whole window
        # freezes with no way back. The wait below is what bounds this.
        $reader = $process.StandardOutput.ReadToEndAsync()
        if (-not $process.WaitForExit(20000)) {
            try { $process.Kill() } catch { }
            return 'failed'
        }
        $output = if ($reader.Wait(2000)) { [string]$reader.Result } else { '' }
        $status = @($output -split "`r?`n" | Where-Object { $_.Trim() }) | Select-Object -Last 1
        if (-not $status) { return 'failed' }
        return $status.Trim()
    } catch {
        return 'failed'
    } finally {
        if ($process) { try { $process.Dispose() } catch { } }
    }
}

# Typing at a session means becoming its foreground window and sending
# keystrokes; the agents expose no other way in. That is only safe while the
# window actually in front is the one that was aimed at, so the send is gated on
# re-reading the foreground rather than on having asked for it.
function Send-SessionCommand {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$Command, [int]$SettleMilliseconds = 250)
    # A Herdr pane is not a Windows Terminal tab, but Herdr can type into it:
    # the text goes in as typed, then Enter. There is no window to bring
    # forward, so the foreground checks of the tab route do not apply.
    if ($Session.PSObject.Properties['TerminalHost'] -and $Session.TerminalHost -eq 'Herdr') {
        if (-not $Session.HerdrPane -or -not $Session.HerdrExe) { return 'privateherdr' }
        $typed = Invoke-HerdrJson -Exe $Session.HerdrExe -Session $Session.HerdrSession -EnvKey $Session.HerdrEnvKey -AcceptEmpty `
            -Arguments @('pane', 'send-text', [string]$Session.HerdrPane, $Command)
        if (-not $typed -or -not $typed.PSObject.Properties['result']) { return 'failed' }
        Start-Sleep -Milliseconds ([math]::Max(150, $SettleMilliseconds))
        $entered = Invoke-HerdrJson -Exe $Session.HerdrExe -Session $Session.HerdrSession -EnvKey $Session.HerdrEnvKey -AcceptEmpty `
            -Arguments @('pane', 'send-keys', [string]$Session.HerdrPane, 'Enter')
        if (-not $entered -or -not $entered.PSObject.Properties['result']) { return 'failed' }
        return 'sent'
    }
    return (Invoke-TabAgent -Session $Session -Command $Command -SettleMilliseconds $SettleMilliseconds)
}

# One wording for a failed hand-off, so the row menu and Compact all cannot
# drift apart.
function Get-TabAgentReason {
    param([string]$Status)
    switch ($Status) {
        'ambiguous' { 'two tabs look identical' }
        'notfound'  { 'tab not found' }
        'privateherdr' { 'it runs in a private Herdr server the launcher cannot reach, so switch to it in Herdr yourself' }
        'focus'     { 'window would not come forward' }
        'moved'     { 'focus moved away mid-command, left unsent' }
        default     { 'the tab helper did not answer' }
    }
}

# A title the user typed always wins. Otherwise show what the transcript says
# the session is about; the start time is only a stand-in for a session that
# has not been given a prompt yet.
function Get-SessionTitle {
    param($Session)
    $given = Get-UserSessionTitle $Session
    if ($given) { return $given }
    if ($Session.AutoTitle) { return [string]$Session.AutoTitle }
    return 'New session {0}' -f ([datetime]$Session.Started).ToString('HH:mm')
}

# A session the launcher started carries a short marker in its terminal title,
# which is how a title typed in New session finds its way to the live row.
function Get-UserSessionTitle {
    param($Session)
    if ($Session.SessionKey -and $script:sessionTitles.ContainsKey([string]$Session.SessionKey)) {
        return [string]$script:sessionTitles[[string]$Session.SessionKey]
    }
    if ([string]$Session.WindowTitle -match '#([0-9a-f]{6})\s*$') {
        $markerKey = 'marker:' + $Matches[1]
        if ($script:sessionTitles.ContainsKey($markerKey)) { return [string]$script:sessionTitles[$markerKey] }
    }
    return ''
}

function Get-SessionTitleSource {
    param($Session)
    if ($Session.SessionKey -and $script:sessionTitles.ContainsKey([string]$Session.SessionKey)) { return 'set by you with Set session title' }
    if (Get-UserSessionTitle $Session) { return 'given by you when the session was started' }
    if ($Session.AutoTitle) { return 'taken from {0}; set your own with Set session title' -f $Session.AutoTitleSource }
    return 'no prompt has been written to this session yet'
}

function Get-SessionName {
    param($Session)
    $project = if ($Session.Project) { [string]$Session.Project } else { '(unknown)' }
    return '{0} - {1}' -f $project, (Get-SessionTitle $Session)
}

# Clicking a row opens this. Going to a session types nothing at all: the tab is
# selected and the caret put in its prompt, which is the whole of what is needed
# to carry on typing there by hand. Only the second item sends keystrokes.
$script:menuSession = $null
$script:sessionMenu = New-Object System.Windows.Forms.ContextMenuStrip
$script:sessionMenu.Font = $fontBase
$script:sessionMenu.ShowImageMargin = $false
$script:sessionMenu.BackColor = $theme.Field
$script:sessionMenu.ForeColor = $theme.Head
$menuColors = New-Object Launcher.DarkMenuColors($theme.Field, $theme.Border, $theme.Border)
$script:sessionMenu.Renderer = New-Object System.Windows.Forms.ToolStripProfessionalRenderer($menuColors)

$script:menuHeader = $script:sessionMenu.Items.Add('session')
$script:menuHeader.Enabled = $false
[void]$script:sessionMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$script:menuGo = $script:sessionMenu.Items.Add('Go to this session')
$script:menuGo.ForeColor = $theme.Head
$script:menuRename = $script:sessionMenu.Items.Add('Set session title...')
$script:menuRename.ForeColor = $theme.Head
$script:menuCompact = $script:sessionMenu.Items.Add('Compact this session')
$script:menuCompact.ForeColor = $theme.Head
# Nothing is typed anywhere yet: this only opens the handoff in the New session
# view, where the receiving agent is chosen and the handoff confirmed.
$script:menuHandoff = $script:sessionMenu.Items.Add('Hand off this session...')
$script:menuHandoff.ForeColor = $theme.Head
$script:menuCancelPlanned = $script:sessionMenu.Items.Add('Cancel planned handoff')
$script:menuCancelPlanned.ForeColor = $theme.Head
$script:menuManualPlanned = $script:sessionMenu.Items.Add('Complete planned handoff manually...')
$script:menuManualPlanned.ForeColor = $theme.Head

function Show-SessionMenu {
    param([Parameter(Mandatory)]$Session)
    $script:menuSession = $Session
    $script:menuHeader.Text = '{0}  {1}' -f $Session.Agent, (Get-SessionName $Session)
    $hasPlan = $script:plannedHandoffs.ContainsKey([string]$Session.AgentId)
    $script:menuHandoff.Enabled = -not $hasPlan
    $script:menuCancelPlanned.Visible = $hasPlan
    $script:menuManualPlanned.Visible = $hasPlan
    $script:sessionMenu.Show([System.Windows.Forms.Cursor]::Position)
}

$script:menuRename.Add_Click({
    $session = $script:menuSession
    if (-not $session) { return }
    $current = Get-SessionTitle $session
    $title = [Microsoft.VisualBasic.Interaction]::InputBox('Enter a short title for this live session.', 'Session title', $current)
    if ([string]::IsNullOrWhiteSpace($title)) { return }
    $title = $title.Trim()
    if ($title.Length -gt 80) { $title = $title.Substring(0, 80).TrimEnd() }
    $script:sessionTitles[[string]$session.SessionKey] = $title
    $saveError = Save-SessionTitles
    if ($saveError) {
        [void][System.Windows.Forms.MessageBox]::Show($form, ('Could not save session titles: ' + $saveError), 'Session title')
    }
    Refresh-LiveSessions
})

function Test-HandoffStatusReady {
    param([AllowEmptyString()][string]$Text)
    if (Test-HandoffStatusEmpty $Text) { return $false }
    $headings = @()
    foreach ($line in @(([string]$Text) -split '\r?\n')) {
        if ($line -match '^###\s+(.+?)\s*$') { $headings += $Matches[1] }
    }
    foreach ($heading in $handoffHeadings) {
        if ($headings -notcontains $heading) { return $false }
    }
    return $true
}

# The labels cover their row, so each one carries the row's handlers too and the
# sender is either the row or a label sitting on it.
function Get-RowPanel {
    param($Control)
    if ($Control -is [System.Windows.Forms.Label]) { return $Control.Parent }
    return $Control
}

# One set of handlers for every row, written here rather than built per row in
# the loop. A scriptblock closed over the loop with GetNewClosure is bound to a
# module of its own, from which neither $theme nor this script's functions are
# visible, so it throws where it stands and the row simply never lights up.
$script:rowEnter = {
    $row = Get-RowPanel $this
    if ($row) {
        $row.BackColor = $theme.Field
        $row.Invalidate($true)
    }
}
$script:rowLeave = {
    $row = Get-RowPanel $this
    if (-not $row) { return }
    # Moving from the row onto one of its own labels raises MouseLeave without
    # the pointer having left the row, so ask where it actually is.
    $where = $row.PointToClient([System.Windows.Forms.Cursor]::Position)
    if (-not $row.ClientRectangle.Contains($where)) {
        $row.BackColor = $theme.Panel
        $row.Invalidate($true)
    }
}
$script:rowClick = {
    $row = Get-RowPanel $this
    if ($row -and $row.Tag) { Show-SessionMenu -Session $row.Tag }
}

$script:menuGo.Add_Click({
    $session = $script:menuSession
    if (-not $session) { return }
    $name = Get-SessionName $session
    $uiLiveSummary.Text = 'Bringing {0} to the front...' -f $name
    [System.Windows.Forms.Application]::DoEvents()
    $status = if ($session.TerminalHost -eq 'Herdr') { Invoke-HerdrGoTo -Session $session } else { Invoke-TabAgent -Session $session }
    if ($status -eq 'shown') {
        $uiLiveSummary.Text = '{0} is in front with the caret in its prompt.' -f $name
    } else {
        [void][Launcher.WindowFocus]::Activate($form.Handle)
        $uiLiveSummary.Text = 'Could not reach {0}: {1}.' -f $name, (Get-TabAgentReason $status)
    }
})

$script:menuCompact.Add_Click({
    $session = $script:menuSession
    if (-not $session) { return }
    $name = Get-SessionName $session
    $uiLiveSummary.Text = 'Typing /compact into {0}...' -f $name
    [System.Windows.Forms.Application]::DoEvents()
    $status = Send-SessionCommand -Session $session -Command '/compact'
    $sent = ($status -eq 'sent')
    # A session that took the command stays in front so the compaction can be
    # watched. Come back here only to report one that did not.
    if (-not $sent) { [void][Launcher.WindowFocus]::Activate($form.Handle) }
    Refresh-LiveSessions
    $uiLiveSummary.Text = if ($sent) {
        'Sent /compact to {0}.' -f $name
    } else {
        '{0} was left untouched: {1}.' -f $name, (Get-TabAgentReason $status)
    }
})

$script:menuHandoff.Add_Click({
    $session = $script:menuSession
    if (-not $session) { return }
    Enter-HandoffMode -Session $session
})
$script:menuCancelPlanned.Add_Click({
    $session = $script:menuSession
    if (-not $session) { return }
    Stop-PlannedHandoff -Key ([string]$session.AgentId)
    $uiLiveSummary.Text = 'Planned handoff cancelled. Any checkpoint request already sent cannot be recalled.'
    Refresh-LiveSessions
})
$script:menuManualPlanned.Add_Click({
    $session = $script:menuSession
    if (-not $session) { return }
    $key = [string]$session.AgentId
    if (-not $script:plannedHandoffs.ContainsKey($key)) { return }
    $plan = $script:plannedHandoffs[$key]
    $status = Get-ManualHandoffStatus -Handoff $plan.Handoff
    if ($null -eq $status -or (Test-HandoffStatusEmpty $status)) { return }
    try { Complete-PlannedHandoff -Plan $plan -StatusSource 'manual' -StatusText $status }
    catch { [void][System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'Cannot complete handoff') }
})

function Show-LiveSessionTerminal {
    param([Parameter(Mandatory)]$Session)

    $status = Invoke-TabAgent -Session $Session
    $activated = ($status -eq 'shown')
    if (-not $activated -and $status -eq 'ambiguous') {
        [void][System.Windows.Forms.MessageBox]::Show(
            $form,
            'Two terminal tabs look identical, so the launcher will not guess. Restart the older Codex session once to give its tab the new >_ marker.',
            'Cannot identify the exact tab',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
        return
    }
    try {
        $terminalProcess = Get-Process -Id ([int]$Session.TerminalId) -ErrorAction Stop
        if (-not $activated -and $terminalProcess.MainWindowHandle -ne [System.IntPtr]::Zero) {
            $activated = [Launcher.WindowFocus]::Activate($terminalProcess.MainWindowHandle)
        }
    } catch { }

    if (-not $activated) {
        $shell = $null
        try {
            $shell = New-Object -ComObject WScript.Shell
            $activated = $shell.AppActivate([int]$Session.TerminalId)
        } catch { }
        finally {
            if ($shell) {
                try { [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) } catch { }
            }
        }
    }

    if (-not $activated) {
        [void][System.Windows.Forms.MessageBox]::Show(
            $form,
            'The exact terminal tab could not be identified. It may have closed since the list was loaded; click Refresh and try again.',
            'Terminal tab not found',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
    }
}

function Update-LiveTableLayout {
    if (-not $uiLiveRows -or -not $uiLiveProjectHeader) { return }
    $rowWidth = [Math]::Max(0, $uiLiveRows.ClientSize.Width -
        [System.Windows.Forms.SystemInformation]::VerticalScrollBarWidth)
    $gap = 10
    $availableWidth = [Math]::Max(1, $rowWidth - (($script:liveColumnKeys.Count - 1) * $gap))
    $widths = @{}
    $usedWidth = 0
    for ($i = 0; $i -lt $script:liveColumnKeys.Count; $i++) {
        $key = $script:liveColumnKeys[$i]
        if ($i -eq $script:liveColumnKeys.Count - 1) {
            $widths[$key] = [Math]::Max(1, $availableWidth - $usedWidth)
        } else {
            $widths[$key] = [int][Math]::Floor($availableWidth * [double]$script:liveColumnFractions[$key])
            $usedWidth += $widths[$key]
        }
    }
    $positions = @{}
    $x = 0
    foreach ($key in $script:liveColumnKeys) {
        $positions[$key] = $x
        $x += $widths[$key] + $gap
    }
    $script:liveColumnWidths = $widths
    $headerMap = @{
        Agent = $uiLiveAgentHeader; Project = $uiLiveProjectHeader
        Model = $uiLiveModelHeader; Effort = $uiLiveEffortHeader; Context = $uiLiveContextHeader
        Permission = $uiLivePermissionHeader
    }
    foreach ($key in $script:liveColumnKeys) {
        $headerMap[$key].Left = 16 + $positions[$key]
        $headerMap[$key].Width = $widths[$key]
    }
    $uiLiveRule.Width = [Math]::Max(1, $livePanel.ClientSize.Width - 32)
    for ($i = 0; $i -lt $script:liveSplitters.Count; $i++) {
        $key = $script:liveColumnKeys[$i]
        $splitter = $script:liveSplitters[$i]
        $splitter.Left = 16 + $positions[$key] + $widths[$key] - [int][Math]::Floor($splitter.Width / 2)
    }
    foreach ($row in @($uiLiveRows.Controls | Where-Object { $_.Tag -and $_.Tag -isnot [string] })) {
        $row.Width = $rowWidth
        foreach ($control in $row.Controls) {
            switch ([string]$control.Tag) {
                'agent' { $control.Left = $positions.Agent; $control.Width = $widths.Agent }
                'project' { $control.Left = $positions.Project; $control.Width = $widths.Project }
                'model' { $control.Left = $positions.Model; $control.Width = $widths.Model }
                'effort' { $control.Left = $positions.Effort; $control.Width = $widths.Effort }
                'context' { $control.Left = $positions.Context; $control.Width = $widths.Context }
                'permission' { $control.Left = $positions.Permission; $control.Width = $widths.Permission }
            }
        }
    }
}

# Every live session of one agent carries the same account reading, so the
# first one stands for the agent. An agent with no live session is left out
# rather than shown with a stale number.
function Update-LiveLimits {
    # One line per agent, the numbers lined up in a column of their own.
    $top = 34
    $nameWidth = [System.Windows.Forms.TextRenderer]::MeasureText('Claude:', $uiLiveClaudeName.Font).Width + 6
    foreach ($entry in @(
        @{ Agent = 'Claude'; Name = $uiLiveClaudeName; Value = $uiLiveClaudeValue },
        @{ Agent = 'Codex'; Name = $uiLiveCodexName; Value = $uiLiveCodexValue }
    )) {
        $session = @($script:liveSessions | Where-Object { $_.Agent -eq $entry.Agent }) | Select-Object -First 1
        if (-not $session) {
            $entry.Name.Text = ''
            $entry.Value.Text = ''
            Set-RowTip $entry.Name ''
            Set-RowTip $entry.Value ''
            continue
        }
        # The name keeps the agent's colour; the number carries the health:
        # green below 60%, amber from 60%, red from 80%, by the higher window.
        $valueColor = $theme.Muted
        $limitMatch = [regex]::Match([string]$session.UsageDisplay, '^\s*(\d+(?:\.\d+)?)/(\d+(?:\.\d+)?)%')
        if ($limitMatch.Success) {
            $valueColor = $theme.Value
            $highestUse = [Math]::Max([double]$limitMatch.Groups[1].Value, [double]$limitMatch.Groups[2].Value)
            if ($highestUse -ge 80) { $valueColor = $theme.Danger }
            elseif ($highestUse -ge 60) { $valueColor = $theme.Warning }
        }
        $entry.Name.Text = '{0}:' -f $entry.Agent
        $entry.Name.Top = $top
        $entry.Name.Width = $nameWidth
        $entry.Value.Text = [string]$session.UsageDisplay
        $entry.Value.ForeColor = $valueColor
        $entry.Value.Top = $top
        $entry.Value.Left = $edgeL + $nameWidth
        $top += 17
        $tip = '{0} account limits: 5-hour window / 7-day window.{1}{1}{2}{1}{1}Green below 60%, amber from 60%, red from 80%.' -f $entry.Agent, "`r`n", $session.UsageDetail
        Set-RowTip $entry.Name $tip
        Set-RowTip $entry.Value $tip
    }
}

function Refresh-LiveSessions {
    param([switch]$RefreshAccountUsage)
    if ($RefreshAccountUsage) {
        $uiLiveSummary.Text = 'Refreshing sessions and account limits...'
        [System.Windows.Forms.Application]::DoEvents()
    }
    $script:liveSessions = @(Get-LiveAgentSessions)
    # A title the user gave a session also goes on its Herdr tab, once.
    foreach ($liveSession in $script:liveSessions) {
        if ($liveSession.TerminalHost -ne 'Herdr' -or -not $liveSession.HerdrPane) { continue }
        $givenTitle = Get-UserSessionTitle $liveSession
        if (-not $givenTitle) { continue }
        $appliedKey = '{0}|{1}|{2}' -f $liveSession.HerdrSession, $liveSession.HerdrPane, $givenTitle
        if ($script:herdrTitleApplied.ContainsKey($appliedKey)) { continue }
        $script:herdrTitleApplied[$appliedKey] = $true
        [void](Set-HerdrTabTitle -Exe $liveSession.HerdrExe -Session $liveSession.HerdrSession -EnvKey $liveSession.HerdrEnvKey -PaneId $liveSession.HerdrPane -Title $givenTitle)
    }
    if ($script:liveProjectSortDescending -ne $null) {
        $script:liveSessions = @($script:liveSessions | Sort-Object @{Expression={ [string]$_.Project }; Descending=[bool]$script:liveProjectSortDescending}, @{Expression='Started';Descending=$true})
    }
    if ($RefreshAccountUsage -and @($script:liveSessions | Where-Object { $_.Agent -eq 'Claude' }).Count -gt 0) {
        $freshClaudeUsage = Get-ClaudeAccountUsage
        if ($freshClaudeUsage) { $script:claudeAccountUsage = $freshClaudeUsage }
    }
    if ($script:claudeAccountUsage) {
        foreach ($session in @($script:liveSessions | Where-Object { $_.Agent -eq 'Claude' })) {
            $session.UsageDisplay = $script:claudeAccountUsage.Display
            $session.UsageDetail = $script:claudeAccountUsage.Detail +
                ("`r`nMeasured {0:g}." -f $script:claudeAccountUsage.MeasuredAt)
            $session.UsageMeasuredAt = $script:claudeAccountUsage.MeasuredAt
        }
    } elseif ($script:claudeUsageStatus) {
        # A failed check is worth saying out loud: an empty Limits column reads
        # as "no limits" rather than "could not ask".
        foreach ($session in @($script:liveSessions | Where-Object { $_.Agent -eq 'Claude' })) {
            $session.UsageDisplay = 'retry'
            $session.UsageDetail = $script:claudeUsageStatus
        }
    }
    $uiLiveRows.SuspendLayout()
    foreach ($control in @($uiLiveRows.Controls)) { $control.Dispose() }
    $uiLiveRows.Controls.Clear()
    if ($script:liveSessions.Count -eq 0) {
        [void](New-ThemeText $uiLiveRows 'No live terminal sessions.' 0 8 $theme.Muted 500 $fontBase)
    } else {
        $rowIndex = 0
        # Always leave room for the vertical scrollbar. A row sized to the full
        # client width would overflow the moment the list grows enough to need
        # one, and the panel would try to scroll sideways.
        $rowWidth = [Math]::Max(0, $uiLiveRows.ClientSize.Width -
            [System.Windows.Forms.SystemInformation]::VerticalScrollBarWidth)
        Update-LiveTableLayout
        foreach ($session in $script:liveSessions) {
            # A panel per row, so the whole line is one click target and can
            # light up under the pointer. The labels sit inside it.
            $row = New-Object Launcher.BufferedPanel
            $row.Location = New-Object System.Drawing.Point(0, ($rowIndex * 30))
            $row.Size = New-Object System.Drawing.Size($rowWidth, 28)
            $row.BackColor = $theme.Panel
            $row.Cursor = [System.Windows.Forms.Cursors]::Hand
            $row.Tag = $session
            $uiLiveRows.Controls.Add($row)

            $y = 4
            $agentColor = switch ($session.Agent) {
                'Claude' { $theme.Claude }
                'Codex'  { $theme.Section }
                default  { $theme.Head }
            }
            $agentLabel = New-ThemeText $row $session.Agent 0 $y $agentColor 56 $fontBase
            $projectText = if ($session.Project) { $session.Project } else { '(unknown)' }
            if ($script:plannedHandoffs.ContainsKey([string]$session.AgentId)) { $projectText += '  [planned]' }
            $sessionTitle = Get-SessionTitle $session
            $projectDisplay = '{0} - {1}' -f $projectText, $sessionTitle
            $projectLabel = New-ThemeText $row $projectDisplay 66 $y $theme.Head 320 $fontBase
            $modelLabel = New-ThemeText $row $session.Model 396 $y $theme.Value 80 $fontBase
            Set-RowTip $modelLabel ('{0} ({1})' -f $session.ModelDetail, $session.ModelSource)
            $effortColor = if ($session.Effort -eq 'default') { $theme.Muted } else { $theme.Value }
            $effortLabel = New-ThemeText $row $session.Effort 486 $y $effortColor 52 $fontBase
            Set-RowTip $effortLabel ('Reasoning effort: {0} ({1})' -f $session.Effort, $session.EffortSource)
            # The health reading is the colour of the number now, not a word in a
            # column of its own.
            $contextColor = switch ($session.ContextHealth) {
                'Compact' { $theme.Danger }
                'Watch'   { $theme.Warning }
                'OK'      { $theme.Value }
                default   { $theme.Muted }
            }
            $contextLabel = New-ThemeText $row $session.ContextDisplay 548 $y $contextColor 100 $fontBase
            $contextTip = if ($session.ContextTokens -gt 0 -and $session.ContextWindow -gt 0) {
                '{0:N0} of {1:N0} tokens currently used.{2}{2}Green below 60%, amber from 60%, red from 80%.' -f
                    $session.ContextTokens, $session.ContextWindow, "`r`n"
            } elseif ($session.ContextTokens -gt 0) {
                '{0:N0} tokens currently used. Claude does not record the context-window limit here.' -f $session.ContextTokens
            } else {
                '{0} has not written a token measurement yet. It normally appears after the first completed turn; then click Refresh.' -f $session.Agent
            }
            Set-RowTip $contextLabel $contextTip
            # Keep the right edge inside the viewport even when the vertical
            # scrollbar is present; horizontal scrolling is never needed here.
            $permissionLabel = New-ThemeText $row $session.Permission 741 $y $theme.Head 120 $fontBase
            $agentLabel.Tag = 'agent'
            $projectLabel.Tag = 'project'
            $modelLabel.Tag = 'model'
            $effortLabel.Tag = 'effort'
            $contextLabel.Tag = 'context'
            $permissionLabel.Tag = 'permission'
            Set-RowTip $permissionLabel ('Launch permission mode: ' + $session.Permission)
            $projectDetails = @()
            $projectDetails += ('Title {0}.' -f (Get-SessionTitleSource $session))
            $projectDetails += ('Running in {0}' -f $session.TerminalHost)
            if ($session.Workspace) { $projectDetails += $session.Workspace }
            $projectDetails += ('Started {0:g}' -f $session.Started)
            $projectDetails += ('Agent PID {0}; terminal PID {1}' -f $session.AgentId, $session.TerminalId)
            Set-RowTip $projectLabel ((@($projectDisplay) + $projectDetails) -join "`r`n")

            # Every label as well as the row itself, or the pointer falls
            # through the gaps between them. Which row is being pointed at comes
            # from the sender, so all rows share one set of handlers.
            foreach ($target in (@($row) + @($row.Controls))) {
                $target.Add_MouseEnter($script:rowEnter)
                $target.Add_MouseLeave($script:rowLeave)
                $target.Add_Click($script:rowClick)
            }
            Update-LiveTableLayout

            $rowIndex++
        }
    }
    $contentHeight = [Math]::Max(0, 8 + ($script:liveSessions.Count * 30))
    $uiLiveRows.AutoScrollMinSize = New-Object System.Drawing.Size(0, $contentHeight)
    $uiLiveRows.HorizontalScroll.Enabled = $false
    $uiLiveRows.HorizontalScroll.Visible = $false
    $uiLiveRows.ResumeLayout()
    Update-LiveLimits
    $uiLiveSummary.Text = if ($script:liveSessions.Count -eq 1) { '1 live terminal session' } else {
        '{0} live terminal sessions' -f $script:liveSessions.Count
    }
    Set-ThemeButtonAvailable $uiLiveCompact ($script:liveSessions.Count -gt 0)
}

$uiLiveProjectHeader.Add_Click({
    if ($null -eq $script:liveProjectSortDescending) {
        $script:liveProjectSortDescending = $false
    } else {
        $script:liveProjectSortDescending = -not [bool]$script:liveProjectSortDescending
    }
    $uiLiveProjectHeader.Text = if ($script:liveProjectSortDescending) { 'Project (Z-A)' } else { 'Project (A-Z)' }
    Refresh-LiveSessions
})
$form.Add_Resize({
    $panel.Left = [Math]::Max(16, [int][Math]::Floor(($form.ClientSize.Width - $panel.Width) / 2))
    Set-ActionButtonPositions
    if ($uiLiveRows -and $uiLiveRows.IsHandleCreated) { Update-LiveTableLayout }
})
$panel.Left = [Math]::Max(16, [int][Math]::Floor(($form.ClientSize.Width - $panel.Width) / 2))
Set-ActionButtonPositions

# '/compact' is typed into each session in turn. Both CLIs accept it, and both
# take it as an ordinary prompt line, so a session that is mid-answer queues it
# rather than losing it.
function Invoke-CompactAllSessions {
    $targets = @($script:liveSessions)
    if ($targets.Count -eq 0) { return }

    $lines = @($targets | ForEach-Object {
        '    {0}  {1}  ({2})' -f $_.Agent.PadRight(6), $_.Project, $_.ContextDisplay
    })
    $question = @(
        ('Type /compact into these {0} sessions, one after another?' -f $targets.Count),
        ''
    ) + $lines + @(
        '',
        'Windows Terminal tabs are brought to the front in turn, so leave the mouse',
        'and keyboard alone until it finishes. Herdr panes are typed into where they',
        'are. Anything already typed but unsent in a session gets sent along with',
        'the command.'
    )
    $answer = [System.Windows.Forms.MessageBox]::Show(
        $form, ($question -join "`r`n"), 'Compact all live sessions',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    Set-ThemeButtonAvailable $uiLiveCompact $false
    $uiLiveRefresh.Enabled = $false
    $sent = 0
    $skipped = @()
    try {
        $index = 0
        foreach ($session in $targets) {
            $index++
            $uiLiveSummary.Text = 'Compacting {0} of {1}: {2}...' -f $index, $targets.Count, $session.Project
            [System.Windows.Forms.Application]::DoEvents()
            $result = Send-SessionCommand -Session $session -Command '/compact'
            if ($result -eq 'sent') {
                $sent++
            } else {
                $skipped += ('{0} ({1})' -f $session.Project, (Get-TabAgentReason $result))
            }
        }
    } finally {
        $uiLiveRefresh.Enabled = $true
        # Take the foreground back from whichever terminal typed last.
        [void][Launcher.WindowFocus]::Activate($form.Handle)
        Refresh-LiveSessions
    }

    $summary = if ($skipped.Count -eq 0) {
        'Sent /compact to {0} of {1} sessions.' -f $sent, $targets.Count
    } else {
        'Sent /compact to {0} of {1}. Skipped: {2}' -f $sent, $targets.Count, ($skipped -join '; ')
    }
    $uiLiveSummary.Text = $summary
    if ($skipped.Count -gt 0) {
        [void][System.Windows.Forms.MessageBox]::Show(
            $form,
            ($summary + "`r`n`r`nA skipped session was left untouched. Open its tab and run /compact there."),
            'Compact all', [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information)
    }
}

function Set-LauncherView {
    param([ValidateSet('new', 'live')][string]$View)
    $script:launcherView = $View
    $showLive = ($View -eq 'live')
    $panel.Visible = -not $showLive
    $livePanel.Visible = $showLive
    $uiStart.Visible = -not $showLive
    # A handoff has its own Cancel. The ordinary one closes the launcher, and
    # showing both stacked them on top of each other.
    $uiCancel.Visible = (-not $showLive) -and (-not $script:handoffSource)
    $uiHandoffCancel.Visible = (-not $showLive) -and [bool]$script:handoffSource

    $newInk = if ($showLive) { $theme.Label } else { $theme.Section }
    $liveInk = if ($showLive) { $theme.Section } else { $theme.Label }
    $uiNewTab.ForeColor = $newInk
    $uiNewTab.FlatAppearance.BorderColor = $newInk
    $uiLiveTab.ForeColor = $liveInk
    $uiLiveTab.FlatAppearance.BorderColor = $liveInk

    if ($showLive) {
        # One fresh snapshot on entry, including Claude's account limits. There
        # is deliberately no timer; subsequent updates remain behind Refresh.
        Refresh-LiveSessions -RefreshAccountUsage
        Set-ButtonRow -PanelTop $livePanel.Top -PanelHeight $livePanel.Height -MinPanelHeight $script:livePanelHeightMin
        $form.AcceptButton = $uiLiveRefresh
        $form.CancelButton = $null
        $uiLiveRefresh.Focus()
    } else {
        $form.AcceptButton = $uiStart
        $form.CancelButton = if ($script:handoffSource) { $uiHandoffCancel } else { $uiCancel }
        Update-Layout
        Set-ActionButtonPositions
        $uiStart.Focus()
    }
}

function Update-Details {
    $workPath = Get-SelectedProjectPath
    # A handoff belongs to the folder its session runs in. Choosing another
    # folder ends it, rather than writing the handoff somewhere it did not
    # come from.
    if ($script:handoffSource -and -not (Test-SamePath $workPath $script:handoffWorkspace)) {
        Exit-HandoffMode
        return
    }
    Set-ThemeButtonAvailable $uiProjectRemove ([bool]$workPath -and -not $script:handoffSource)

    $attached = @(Get-AttachedContextPaths | Where-Object { -not (Test-SamePath $_ $workPath) })
    if ($attached.Count -eq 0) {
        $uiContextPath.Text = 'none'
    } elseif ($attached.Count -eq 1) {
        $uiContextPath.Text = $attached[0]
    } else {
        $uiContextPath.Text = "({0}) {1}" -f $attached.Count, ($attached -join '   |   ')
    }
    Set-RowTip $uiContextPath ($attached -join "`r`n")

    # The extra folders live behind the disclosure, so the one line that is
    # always visible has to say they exist.
    $scopeNote = if ($attached.Count -eq 1) { '   (+1 folder in scope)' }
        elseif ($attached.Count -gt 1) { '   (+{0} folders in scope)' -f $attached.Count }
        else { '' }
    $uiProjectPath.Text = if ($script:handoffSource) { 'Handoff work folder (fixed): ' + $workPath + $scopeNote }
        elseif ($workPath) { 'Opens in: ' + $workPath + $scopeNote } else { 'Opens in: -' }

    # What this project's own CLAUDE.md / AGENTS.md says about the vault.
    if ($workPath) {
        $vault = Get-VaultLinks $workPath
        $broken = @($vault.Links | Where-Object { -not $_.Exists })
        if ($vault.InstructionFiles.Count -eq 0) {
            $uiVaultLink.Text = 'Vault link: no CLAUDE.md or AGENTS.md in this folder'
            $uiVaultLink.ForeColor = $theme.Muted
        } elseif ($vault.Links.Count -eq 0) {
            $uiVaultLink.Text = 'Vault link: none (' + ($vault.InstructionFiles -join ', ') + ' mentions no vault path)'
            $uiVaultLink.ForeColor = $theme.Muted
        } elseif ($broken.Count -gt 0) {
            $uiVaultLink.Text = 'Vault link BROKEN: ' + (($broken | ForEach-Object { $_.Reference }) -join ', ')
            $uiVaultLink.ForeColor = $theme.Danger
        } else {
            $uiVaultLink.Text = 'Vault link: ' + (($vault.Links | ForEach-Object { Get-VaultRelativeLabel $_.Path }) -join ', ')
            $uiVaultLink.ForeColor = $theme.Value
        }
        # One per line under the cursor, since several of them never fit across.
        Set-RowTip $uiVaultLink (($vault.Links | ForEach-Object { $_.Path }) -join "`r`n")
    } else {
        $uiVaultLink.Text = ''
        Set-RowTip $uiVaultLink ''
    }
    Set-RowTip $uiProjectPath ([string]$workPath)

    # Codex resume takes [SESSION_ID] [PROMPT]; a bare prompt would bind to the
    # session id, so the box is unavailable for that combination.
    # A handoff always starts a new session, whatever the hidden Start box says.
    $resuming = ([string]$uiSessionRole.SelectedItem -ne 'Orchestrator') -and (-not $script:handoffSource) -and ([string]$uiStartMode.SelectedItem -ne $startNewLabel)
    $promptBlocked = $resuming -and ([string]$uiAgent.SelectedItem -eq 'Codex')
    # ReadOnly rather than disabled: a disabled TextBox repaints itself in the
    # system grey and ignores BackColor, which would punch a light hole in the row.
    $uiPrompt.ReadOnly = $promptBlocked
    $uiPrompt.ForeColor = if ($promptBlocked) { $theme.Muted } else { $theme.Value }
    $uiPromptLabel.Text = if ($script:handoffSource) { 'Note (optional)' }
        elseif ($promptBlocked) { 'First message (n/a when resuming)' }
        else { 'First message (optional)' }
    $titleAvailable = ([string]$uiSessionRole.SelectedItem -ne 'Orchestrator') -and (-not $script:handoffSource)
    $uiTitleLabel.Visible = $titleAvailable
    $uiSessionTitle.Parent.Visible = $titleAvailable

    # The persona label keeps its help marker and a fixed width, so the state
    # that used to be in brackets after it goes into the hover text instead.
    $claudeOnly = ([string]$uiAgent.SelectedItem -eq 'Claude')
    $uiPersona.Enabled = $claudeOnly -and ($uiPersona.Items.Count -gt 1)
    $personaState = if (-not $claudeOnly) { 'Unavailable: Codex has no equivalent flag.' }
        elseif ($uiPersona.Items.Count -le 1) { 'Unavailable: no personas defined in this project yet.' }
        else { '' }
    $personaTip = if ($personaState) { $help.Persona + "`r`n`r`n" + $personaState } else { $help.Persona }
    Set-RowTip $uiPersonaLabel $personaTip
    Set-RowTip $uiPersona $personaTip
    $uiVaultLinkSet.Enabled = [bool]$workPath

    $readOnly = ((Get-ModeSlug ([string]$uiMode.SelectedItem)) -eq 'Read-only (plan)')
    $uiContext.Enabled = -not $readOnly
    $uiContextAdd.Enabled = -not $readOnly
    Set-ThemeButtonAvailable $uiContextRemove ((-not $readOnly) -and ($uiContext.SelectedIndex -ge 0))
    Update-Layout
    # In a read-only session nothing is writable, so an extra folder in scope
    # would do nothing at all. Say so rather than letting it look effective.
    if ($readOnly) { $uiContextPath.Text = 'nothing is writable in a read-only session' }
    $uiModel.Enabled = ($uiAgent.SelectedIndex -ge 0)
    if ([string]$uiSessionRole.SelectedItem -eq 'Orchestrator') {
        foreach ($control in @($uiMode, $uiPersona, $uiWeb, $advanced)) { $control.Enabled = $false }
        $uiStartMode.Enabled = $true
        $uiProjectPath.Text = 'Orchestrator project: ' + $workPath
        $uiPromptLabel.Text = 'Goal (optional)'
        $uiRoleNote.Text = 'Delegation, tests and automatic repair'
        Set-RowTip $uiRoleNote 'The selected Claude/Codex model opens as Orchestrator. The controller prepares an isolated project workspace and manages worker checks and repairs. No automatic main merge or deployment.'
    }
    if (-not $script:handoffSource) {
        $uiStart.Text = if ([string]$uiSessionRole.SelectedItem -eq 'Orchestrator') { '[ Orchestrator ]' } else { '[ Ordinary ]' }
    }
}

function Get-ManualHandoffStatus {
    param([Parameter(Mandatory)]$Handoff, [string]$Reason = '')
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = 'Handoff status'
    $dialog.StartPosition = 'CenterParent'
    $dialog.Size = New-Object System.Drawing.Size(720, 600)
    $dialog.BackColor = $theme.Panel
    $dialog.ForeColor = $theme.Head
    $dialog.Font = $fontBase
    $label = New-Object System.Windows.Forms.Label
    # The receiving agent gets this note and nothing of the old conversation,
    # so it has to carry the task itself.
    $why = if ($Reason) { 'The source session could not write this itself: {0}.' -f $Reason } else { 'You chose to write this yourself.' }
    $label.Text = ("This is the briefing the receiving agent starts from. It does not see the old conversation, so say what task it takes over: the goal, what is done, what is in progress and what to do next.`r`n`r`n" + $why)
    $label.Location = New-Object System.Drawing.Point(16, 16)
    $label.Size = New-Object System.Drawing.Size(670, 108)
    $dialog.Controls.Add($label)
    $box = New-Object System.Windows.Forms.TextBox
    $box.Multiline = $true
    $box.ScrollBars = 'Vertical'
    $box.AcceptsReturn = $true
    $box.Location = New-Object System.Drawing.Point(16, 132)
    $box.Size = New-Object System.Drawing.Size(670, 350)
    $box.BackColor = $theme.Field
    $box.ForeColor = $theme.Value
    $box.Text = Get-HandoffStatusTemplate
    $dialog.Controls.Add($box)
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'Use status'
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $ok.Location = New-Object System.Drawing.Point(490, 496)
    $ok.Size = New-Object System.Drawing.Size(95, 30)
    $dialog.Controls.Add($ok)
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancel'
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $cancel.Location = New-Object System.Drawing.Point(591, 496)
    $cancel.Size = New-Object System.Drawing.Size(95, 30)
    $dialog.Controls.Add($cancel)
    $dialog.AcceptButton = $ok
    $dialog.CancelButton = $cancel
    # A multi-line box opens with everything selected, and the first key typed
    # would replace all six headings. Put the caret under the first one.
    $dialog.Add_Shown({
        $firstBreak = $box.Text.IndexOf("`n")
        $box.Select($(if ($firstBreak -ge 0) { $firstBreak + 1 } else { 0 }), 0)
        $box.Focus()
    })
    $result = $dialog.ShowDialog($form)
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
    return [string]$box.Text
}

$script:plannedHandoffs = @{}
$script:lastPlannedClaudeUsageCheck = [datetime]::MinValue
$script:processingPlannedHandoffs = $false

function Get-HandoffUsagePercent {
    param($Session)
    if (-not $Session) { return $null }
    if ($Session.UsageMeasuredAt -le [datetime]::MinValue -or
        ((Get-Date) - $Session.UsageMeasuredAt).TotalMinutes -gt 3) { return $null }
    $match = [regex]::Match([string]$Session.UsageDisplay, '^\s*(\d+(?:\.\d+)?)/(\d+(?:\.\d+)?)%\s*$')
    if (-not $match.Success) { return $null }
    return [math]::Max([double]::Parse($match.Groups[1].Value,
        [System.Globalization.CultureInfo]::InvariantCulture),
        [double]::Parse($match.Groups[2].Value,
        [System.Globalization.CultureInfo]::InvariantCulture))
}

function Stop-PlannedHandoff {
    param([Parameter(Mandatory)][string]$Key, [string]$Reason = '')
    if (-not $script:plannedHandoffs.ContainsKey($Key)) { return }
    $plan = $script:plannedHandoffs[$Key]
    if ($Reason) {
        $uiLiveSummary.Text = $Reason
        $answer = [System.Windows.Forms.MessageBox]::Show($form,
            ($Reason + "`r`n`r`nComplete the planned handoff with a manual status now?"),
            'Planned handoff needs attention', 'YesNo', 'Warning')
        if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
            $manual = Get-ManualHandoffStatus -Handoff $plan.Handoff
            if ($null -ne $manual -and -not (Test-HandoffStatusEmpty $manual)) {
                try { Complete-PlannedHandoff -Plan $plan -StatusSource 'manual' -StatusText $manual; return }
                catch { $Reason += "`r`nManual completion also failed: " + $_.Exception.Message }
            }
        }
        [void][System.Windows.Forms.MessageBox]::Show($form,
            ($Reason + "`r`n`r`nThe pending file remains in .agent/handoffs for inspection. No receiving session was started."),
            'Handoff not completed', 'OK', 'Information')
    }
    [void]$script:plannedHandoffs.Remove($Key)
}

function Request-PlannedCheckpoint {
    param([Parameter(Mandatory)]$Plan)
    if ($Plan.Requested) { return $true }
    $result = Send-SessionCommand -Session $Plan.Source -Command (Get-HandoffRequest -Handoff $Plan.Handoff)
    $Plan | Add-Member -NotePropertyName LastRequestStatus -NotePropertyValue $result -Force
    if ($result -ne 'sent') { return $false }
    $Plan.Requested = $true
    $Plan.RequestedAt = Get-Date
    $Plan.LastStatusStamp = ''
    $uiLiveSummary.Text = 'Checkpoint requested from {0}. Waiting for status.' -f $Plan.Source.Project
    return $true
}

function Complete-PlannedHandoff {
    param([Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][ValidateSet('agent', 'manual')][string]$StatusSource,
        [Parameter(Mandatory)][string]$StatusText)
    if ($script:plannedHandoffs.ContainsKey([string]$Plan.Source.AgentId) -eq $false) { return }
    Complete-HandoffFile -Handoff $Plan.Handoff -StatusSource $StatusSource -StatusText $StatusText
    # The plan was made some time ago; open the recipient where it was asked to
    # open, whatever the Terminal box says now.
    $currentHost = $script:launchTerminalHost
    if ($Plan.PSObject.Properties['TargetHost'] -and $Plan.TargetHost) { $script:launchTerminalHost = [string]$Plan.TargetHost }
    try {
        Start-AgentTerminal -SelectedAgent $Plan.TargetAgent -WorkingDirectory $Plan.Handoff.WorkingDirectory `
            -ContextDirectories $Plan.Contexts -SelectedModel $Plan.TargetModel -SelectedMode $Plan.TargetMode `
            -StartMode $startNewLabel -OpeningPrompt (Get-HandoffPrompt -HandoffPath $Plan.Handoff.Path `
                -WorkingDirectory $Plan.Handoff.WorkingDirectory) -SelectedEffort $Plan.TargetEffort `
            -SelectedPersona $Plan.TargetPersona -SelectedWeb $Plan.TargetWeb
    } finally {
        $script:launchTerminalHost = $currentHost
    }
    [void]$script:plannedHandoffs.Remove([string]$Plan.Source.AgentId)
    $uiLiveSummary.Text = 'Handed {0} to {1} using a {2} checkpoint.' -f $Plan.Source.Project, $Plan.TargetAgent, $StatusSource
    if ($script:launcherView -eq 'live') { Refresh-LiveSessions }
}

function Process-PlannedHandoffs {
    if ($script:plannedHandoffs.Count -eq 0 -or $script:processingPlannedHandoffs) { return }
    $script:processingPlannedHandoffs = $true
    try {
    $sessions = @(Get-LiveAgentSessions)
    $hasClaudeAuto = @($script:plannedHandoffs.Values | Where-Object {
        $_.Timing -eq 'Automatic at 85% account use' -and $_.Source.Agent -eq 'Claude' -and -not $_.Requested
    }).Count -gt 0
    if ($hasClaudeAuto -and $script:claudeUsageEnabled -and
        ((Get-Date) - $script:lastPlannedClaudeUsageCheck).TotalSeconds -ge 60) {
        $script:lastPlannedClaudeUsageCheck = Get-Date
        $latest = Get-ClaudeAccountUsage
        if ($latest) { $script:claudeAccountUsage = $latest }
    }
    if ($script:claudeAccountUsage) {
        foreach ($session in @($sessions | Where-Object { $_.Agent -eq 'Claude' })) {
            $session.UsageDisplay = $script:claudeAccountUsage.Display
            $session.UsageMeasuredAt = $script:claudeAccountUsage.MeasuredAt
        }
    }
    foreach ($key in @($script:plannedHandoffs.Keys)) {
        if (-not $script:plannedHandoffs.ContainsKey($key)) { continue }
        $plan = $script:plannedHandoffs[$key]
        $live = @($sessions | Where-Object { $_.AgentId -eq $plan.Source.AgentId }) | Select-Object -First 1
        if ($live) { $plan.MissingPolls = 0 } else { $plan.MissingPolls++ }
        if (-not $plan.Requested) {
            if (-not $live) {
                if ($plan.MissingPolls -ge 3) {
                    Stop-PlannedHandoff -Key $key -Reason 'The source session was absent from three checks before its automatic checkpoint.'
                }
                continue
            }
            $percent = Get-HandoffUsagePercent -Session $live
            if ($null -ne $percent -and $percent -ge 85) {
                if (-not (Request-PlannedCheckpoint -Plan $plan)) {
                    $detail = Get-TabAgentReason ([string]$plan.LastRequestStatus)
                    Stop-PlannedHandoff -Key $key -Reason ('The source terminal could not receive the checkpoint request: {0}.' -f $detail)
                    continue
                }
            }
        }
        if (-not $plan.Requested) { continue }
        $stamp = Get-HandoffStatusStamp -Path $plan.Handoff.StatusPath
        if ($stamp -and $stamp -eq $plan.LastStatusStamp) {
            $status = Read-HandoffStatus -Path $plan.Handoff.StatusPath
            if (Test-HandoffStatusReady $status) {
                try {
                    Complete-PlannedHandoff -Plan $plan -StatusSource 'agent' -StatusText $status
                    continue
                } catch {
                    Stop-PlannedHandoff -Key $key -Reason ('Could not start the receiving agent: ' + $_.Exception.Message)
                    continue
                }
            }
        }
        $plan.LastStatusStamp = $stamp
        if (-not $live -and -not $stamp -and $plan.MissingPolls -ge 3) {
            Stop-PlannedHandoff -Key $key -Reason 'The source session was absent from three checks without writing a checkpoint.'
        }
    }
    } finally { $script:processingPlannedHandoffs = $false }
}

$script:plannedHandoffTimer = New-Object System.Windows.Forms.Timer
$script:plannedHandoffTimer.Interval = 15000
$script:plannedHandoffTimer.Add_Tick({ Process-PlannedHandoffs })
$script:plannedHandoffTimer.Start()

function Exit-HandoffMode {
    $uiSessionRole.Enabled = $true
    $uiTerminalHost.Enabled = $true
    if ($script:handoffWait) { $script:handoffWait = $null }
    $script:handoffSource = $null
    $script:handoffWorkspace = ''
    $script:handoffSavedPrompt = ''
    $uiHandoffStatus.Tag.Visible = $false
    $uiHandoffTiming.Tag.Visible = $false
    $uiHandoffTimingLabel.Visible = $false
    $uiHandoffCancel.Visible = $false
    $uiCancel.Visible = $true
    Set-ActionButtonPositions
    $form.CancelButton = $uiCancel
    $uiStartMode.Tag.Visible = $true
    $uiStartLabel.Text = 'Start'
    $uiPromptLabel.Location = New-Object System.Drawing.Point(650, 282)
    $uiPromptLabel.Size = New-Object System.Drawing.Size(322, $uiPromptLabel.Height)
    $uiPrompt.Parent.Location = New-Object System.Drawing.Point(650, 304)
    $uiPrompt.Parent.Size = New-Object System.Drawing.Size(322, 26)
    $uiPrompt.Size = New-Object System.Drawing.Size(312, $uiPrompt.Height)
    $uiStart.Text = '[ Open terminal ]'
    $uiProject.Enabled = $true
    Set-ThemeButtonAvailable $uiProjectBrowse $true
    Set-ThemeButtonAvailable $uiProjectRemove $true
    Set-RowTip $uiSessionRole 'Ordinary opens the selected CLI normally. Orchestrator delegates project work and runs its managed checks and repairs.'
    Update-Details
}

function Enter-HandoffMode {
    param([Parameter(Mandatory)]$Session)
    if (-not $Session.Workspace -or -not (Test-Path -LiteralPath $Session.Workspace -PathType Container)) {
        [void][System.Windows.Forms.MessageBox]::Show($form, 'The session workspace is no longer available.', 'Cannot hand off')
        return
    }
    $script:suspendSessionPreference = $true
    try { $uiSessionRole.SelectedItem = 'Ordinary' } finally { $script:suspendSessionPreference = $false }
    # The receiving session is always an ordinary one; Orchestrator starts its
    # own managed session. Where it opens is still the user's choice.
    $uiSessionRole.Enabled = $false
    Set-RowTip $uiSessionRole 'A handoff always opens an Ordinary session. Orchestrator starts its own managed session instead.'
    $script:handoffSource = $Session
    $script:handoffWorkspace = (Resolve-Path -LiteralPath $Session.Workspace).ProviderPath
    $row = @($script:projectRows | Where-Object { Test-SamePath $_.Path $script:handoffWorkspace }) | Select-Object -First 1
    if (-not $row) {
        # A live session can have been opened in a folder picked by full path.
        # Show that exact folder in this handoff without changing the saved list.
        $display = '{0}  -  {1}' -f (Split-Path -Leaf $script:handoffWorkspace),
            (Split-Path -Parent $script:handoffWorkspace)
        $row = [pscustomobject]@{ Display = $display; Path = $script:handoffWorkspace }
        $script:projectRows += $row
        [void]$uiProject.Items.Add($display)
    }
    $uiProject.SelectedItem = $row.Display
    $uiProject.Enabled = $false
    Set-ThemeButtonAvailable $uiProjectBrowse $false
    Set-ThemeButtonAvailable $uiProjectRemove $false
    $targetAgent = if ([string]$Session.Agent -eq 'Claude') { 'Codex' } else { 'Claude' }
    $uiAgent.SelectedItem = $targetAgent
    Load-AgentModel $targetAgent
    Refresh-EffortChoices
    Refresh-PersonaChoices
    $uiHandoffStatus.SelectedIndex = if ($Session.Permission -match 'read|plan') { 1 } else { 0 }
    $uiHandoffStatus.Tag.Visible = $true
    $uiHandoffTiming.SelectedIndex = 1
    $uiHandoffTiming.Tag.Visible = $true
    $uiHandoffTimingLabel.Visible = $true
    $uiHandoffCancel.Visible = $true
    $uiCancel.Visible = $false
    Set-ActionButtonPositions
    $form.CancelButton = $uiHandoffCancel
    # WinForms assigns DialogResult.Cancel to a form's CancelButton. That would
    # close ShowDialog after our click handler, so keep this mode-exit button inert.
    $uiHandoffCancel.DialogResult = [System.Windows.Forms.DialogResult]::None
    $uiStartMode.Tag.Visible = $false
    $uiStartLabel.Text = 'Status'
    $uiPromptLabel.Location = New-Object System.Drawing.Point(768, 282)
    $uiPromptLabel.Size = New-Object System.Drawing.Size(204, $uiPromptLabel.Height)
    $uiPrompt.Parent.Location = New-Object System.Drawing.Point(768, 304)
    $uiPrompt.Parent.Size = New-Object System.Drawing.Size(204, 26)
    $uiPrompt.Size = New-Object System.Drawing.Size(194, $uiPrompt.Height)
    $uiStart.Text = '[ Plan / hand off ]'
    $uiPrompt.Text = ''
    Update-Details
    $uiProject.Enabled = $false
    Set-ThemeButtonAvailable $uiProjectBrowse $false
    Set-ThemeButtonAvailable $uiProjectRemove $false
    Set-LauncherView 'new'
    $uiHandoffStatus.Focus()
}

function Refresh-ProjectList {
    param([string]$KeepSelected)
    $script:projectRows = @(Build-ProjectRows)
    $script:suspendAutoPair = $true
    $uiProject.BeginUpdate()
    $uiProject.Items.Clear()
    foreach ($row in $script:projectRows) { [void]$uiProject.Items.Add($row.Display) }
    $uiProject.EndUpdate()
    $target = 0
    for ($index = 0; $index -lt $script:projectRows.Count; $index++) {
        if (Test-SamePath $script:projectRows[$index].Path $KeepSelected) { $target = $index; break }
    }
    if ($script:projectRows.Count -gt 0) { $uiProject.SelectedIndex = $target }
    $script:suspendAutoPair = $false
}

# --------------------------------------------------------------- handlers ---

$uiProject.Add_SelectedIndexChanged({
    if ($script:suspendAutoPair) { Update-Details; return }
    # Keep what the outgoing project had before loading the incoming one, so
    # switching A -> B -> A brings A's folders back.
    Save-ProjectContexts
    Save-ProjectMode
    Load-ProjectContexts (Get-SelectedProjectPath)
    Load-ProjectMode (Get-SelectedProjectPath)
    Refresh-PersonaChoices
    Update-Details
})
$uiContext.Add_SelectedIndexChanged({ Update-Details })
$uiMode.Add_SelectedIndexChanged({ Update-Details })
$uiStartMode.Add_SelectedIndexChanged({ Update-Details })
$uiModel.Add_SelectedIndexChanged({ Refresh-EffortChoices })
$uiAgent.Add_SelectedIndexChanged({
    Save-AgentModel
    Load-AgentModel ([string]$uiAgent.SelectedItem)
    Refresh-EffortChoices
    Update-Details
})
$uiModel.Add_SelectedIndexChanged({
    if ($script:suspendModelPrompt) { return }
    if ([string]$uiModel.SelectedItem -ne $modelOtherLabel) {
        $script:lastModelChoice = [string]$uiModel.SelectedItem
        return
    }
    $typed = [Microsoft.VisualBasic.Interaction]::InputBox(
        "Model name to pass to $($uiAgent.SelectedItem):", 'Other model', '')
    $typed = ([string]$typed).Trim()
    if ($typed) { Set-ModelSelection $typed; $script:lastModelChoice = $typed }
    else { Set-ModelSelection $script:lastModelChoice }
})

# Get-Content piped into Set-Content -Encoding UTF8 re-encodes a BOM-less UTF-8
# file as if it were ANSI, so an em dash in someone's AGENTS.md comes back as
# mojibake. Read and write the bytes deliberately instead.
function Read-InstructionLines {
    param([Parameter(Mandatory)][string]$Path)
    return @([System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) -split '\r?\n')
}

function Write-InstructionLines {
    param([Parameter(Mandatory)][string]$Path, [AllowEmptyCollection()][string[]]$Lines)
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, (($Lines -join "`r`n").TrimEnd() + "`r`n"), $encoding)
}

# What counts as a link line. 'Vault notes:' is only the form this launcher
# writes; the projects that came before it say 'Vision & notes:', 'Master copy:',
# 'Datamodel:' and so on. The shape is what matters: a short label, a colon, and
# a vault path filling the rest of the line, optionally as a list item. A
# sentence that happens to mention a vault path is prose and stays.
$vaultLinePattern = '(?i)^\s*(?:[-*]\s+)?[^:\x60]{1,60}:\s*\x60?[^\x60]*' +
                    [regex]::Escape((Split-Path -Leaf $vaultRoot)) +
                    '[\\/][^\x60]*\x60?\s*\.?\s*$'

function Get-VaultLinkLines {
    param([Parameter(Mandatory)][string]$ProjectPath)
    $found = @()
    foreach ($name in @('AGENTS.md', 'CLAUDE.md')) {
        $file = Join-Path $ProjectPath $name
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
        foreach ($line in (Read-InstructionLines $file)) {
            if ($line -match $vaultLinePattern) { $found += [pscustomobject]@{ File = $name; Line = $line.Trim() } }
        }
    }
    return @($found)
}

function Remove-ProjectVaultLink {
    param([Parameter(Mandatory)][string]$ProjectPath)
    $changed = @()
    foreach ($name in @('AGENTS.md', 'CLAUDE.md')) {
        $file = Join-Path $ProjectPath $name
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
        $lines = Read-InstructionLines $file
        $kept = @($lines | Where-Object { $_ -notmatch $vaultLinePattern })
        if ($kept.Count -eq $lines.Count) { continue }
        # Taking a line out between two blanks would leave a double gap behind.
        $tidied = @()
        foreach ($line in $kept) {
            if ([string]::IsNullOrWhiteSpace($line) -and $tidied.Count -gt 0 -and
                [string]::IsNullOrWhiteSpace($tidied[$tidied.Count - 1])) { continue }
            $tidied += $line
        }
        Write-InstructionLines $file $tidied
        $changed += $name
    }
    return @($changed)
}

# Writes the vault link into the project's own AGENTS.md, with CLAUDE.md left as
# a pointer to it. One shared file every tool reads, rather than one per tool.
function Set-ProjectVaultLink {
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][string]$VaultPath
    )
    $projectName = Split-Path -Leaf $ProjectPath
    $agentsFile  = Join-Path $ProjectPath 'AGENTS.md'
    $claudeFile  = Join-Path $ProjectPath 'CLAUDE.md'
    $linkLine    = 'Vault notes: `' + ($VaultPath -replace '\\', '/') + '`'
    $created     = @()

    if (Test-Path -LiteralPath $agentsFile -PathType Leaf) {
        $lines = Read-InstructionLines $agentsFile
        $existing = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s*Vault notes:') { $existing = $i; break }
        }
        if ($existing -ge 0) {
            $lines[$existing] = $linkLine
            # Re-linking normalises: one owned line, however many were there.
            # A range that runs backwards would silently reverse the tail, so
            # the last-line case has to be handled rather than computed.
            $tail = @()
            if (($existing + 1) -lt $lines.Count) {
                $tail = @($lines[($existing + 1)..($lines.Count - 1)] | Where-Object { $_ -notmatch '^\s*Vault notes:' })
            }
            $lines = @($lines[0..$existing]) + $tail
        } elseif ($lines.Count -gt 0) {
            # Sits just under the title so it is the first thing an agent reads.
            $lines = @($lines[0]) + @('', $linkLine) + @($lines[1..($lines.Count - 1)])
        } else {
            $lines = @($linkLine)
        }
        Write-InstructionLines $agentsFile $lines
    } else {
        Write-InstructionLines $agentsFile @("# $projectName", '', $linkLine)
        $created += 'AGENTS.md'
    }

    if (-not (Test-Path -LiteralPath $claudeFile -PathType Leaf)) {
        Write-InstructionLines $claudeFile @(('# ' + $projectName + ' ' + [char]0x2014 + ' Claude Context'), '',
          'Read `AGENTS.md` in this folder. It is the shared context file, written',
          'tool-independently so Claude Code, Codex and other agents all read the same thing.')
        $created += 'CLAUDE.md'
    }
    return @($created)
}

$uiVaultLinkSet.Add_Click({
    $workPath = Get-SelectedProjectPath
    if (-not $workPath) { return }

    # Linking used to be one-way. When a link this launcher wrote is already
    # there, ask before overwriting it, and offer to take it out again.
    $existing = @(Get-VaultLinkLines $workPath)
    if ($existing.Count -gt 0) {
        # Every owned line gets its own row, so a second link is visible here
        # even when the one-line label upstairs has run out of room for it.
        # Show the lines exactly as they will be deleted, so nothing goes out of
        # a file unseen. A long list is capped rather than growing the dialog.
        $rows = @($existing | Select-Object -First 6 | ForEach-Object {
            '  {0}   ({1})' -f ($_.Line -replace '`', ''), $_.File
        })
        if ($existing.Count -gt 6) { $rows += '  ... and {0} more' -f ($existing.Count - 6) }
        $headline = if ($existing.Count -eq 1) {
            '{0} links to the vault on this line:' -f (Split-Path -Leaf $workPath)
        } else {
            '{0} has {1} vault link lines. Remove takes out all of them:' -f (Split-Path -Leaf $workPath), $existing.Count
        }
        $answer = Show-ThemedChoice -Title 'Vault link' `
            -Message (@($headline) + $rows) `
            -Options @('Choose another', 'Remove link', 'Cancel')
        if ($answer -eq 'Remove link') {
            $cleared = @(Remove-ProjectVaultLink -ProjectPath $workPath)
            Update-Details
            # A project may still contain its own prose references after the
            # launcher-owned link line has been removed.
            $leftover = @((Get-VaultLinks $workPath).Links)
            $note = if ($leftover.Count -gt 0) {
                "`n`nNote: " + ($cleared -join ', ') + ' still mentions ' +
                (($leftover | ForEach-Object { $_.Reference }) -join ', ') + ' in its own text.'
            } else { '' }
            [void][System.Windows.Forms.MessageBox]::Show($form,
                "Vault link removed from: " + ($cleared -join ', ') + $note, 'Vault link removed')
            return
        }
        if ($answer -ne 'Choose another') { return }
    }

    $picked = Show-FolderPicker -Roots @($vaultRoot) -Title 'Choose the notes folder this project links to' -Initial $projectsRoot
    if (-not $picked) { return }
    $created = @(Set-ProjectVaultLink -ProjectPath $workPath -VaultPath $picked)
    Update-Details
    $note = if ($created.Count -gt 0) { "`n`nCreated: " + ($created -join ', ') } else { '' }
    [void][System.Windows.Forms.MessageBox]::Show($form,
        "$(Split-Path -Leaf $workPath) now links to:`n$picked`n`nWritten to AGENTS.md.$note",
        'Vault link updated')
})

$uiProjectBrowse.Add_Click({
    # In a handoff the folder is fixed; the button stays visible but does nothing.
    if ($null -ne $uiProjectBrowse.Tag -and -not [bool]$uiProjectBrowse.Tag) { return }
    # A work folder can be a project or a notes folder.
    $picked = Show-FolderPicker -Roots @($codeProjectsRoot, $vaultRoot) -AllowAnywhere `
        -Title 'Choose a work folder' -Initial (Get-SelectedProjectPath)
    if (-not $picked) { return }
    $script:hiddenProjects = @($script:hiddenProjects | Where-Object { -not (Test-SamePath $_ $picked) })
    if (-not (Test-PathInList $picked $script:savedProjects)) { $script:savedProjects = @($script:savedProjects + $picked) }
    Save-ProjectContexts
    Save-ProjectMode
    Save-LauncherSettings
    Refresh-ProjectList -KeepSelected $picked
    Load-ProjectContexts $picked
    Load-ProjectMode $picked
    Update-Details
})

$uiProjectRemove.Add_Click({
    if ($null -ne $uiProjectRemove.Tag -and -not [bool]$uiProjectRemove.Tag) { return }
    $workPath = Get-SelectedProjectPath
    if (-not $workPath) { return }
    if ($script:projectRows.Count -le 1) { return }
    $script:savedProjects  = @($script:savedProjects | Where-Object { -not (Test-SamePath $_ $workPath) })
    if (-not (Test-PathInList $workPath $script:hiddenProjects)) { $script:hiddenProjects = @($script:hiddenProjects + $workPath) }
    Save-LauncherSettings
    Refresh-ProjectList -KeepSelected ''
    Update-Details
})

$uiContextAdd.Add_Click({
    # Write access is not a notes-only concern: a session may legitimately need
    # G:\My Drive, Downloads or a folder outside both trees. Vault and code
    # projects stay on top as shortcuts; every drive sits below them.
    $start = if ($script:contextPaths.Count -gt 0) { $script:contextPaths[-1] } else { $projectsRoot }
    $picked = Show-FolderPicker -Roots @($vaultRoot, $codeProjectsRoot) -AllowAnywhere `
        -Title 'Choose a folder the agent may also write in' -Initial $start
    if (-not $picked) { return }
    if (Test-SamePath $picked (Get-SelectedProjectPath)) {
        [void][System.Windows.Forms.MessageBox]::Show($form, 'That is already the project folder.', 'Already attached')
        return
    }
    Set-AttachedContextPaths -Paths @(@(Get-AttachedContextPaths) + $picked) -Select $picked
    Update-Details
})

$uiContextRemove.Add_Click({
    if (-not [bool]$uiContextRemove.Tag) { return }
    $index = $uiContext.SelectedIndex
    if ($index -lt 0) { return }
    $dropped = $script:contextPaths[$index]
    $remaining = @(Get-AttachedContextPaths | Where-Object { -not (Test-SamePath $_ $dropped) })
    # Land on the neighbour that took its place.
    $next = if ($remaining.Count -eq 0) { '' } else { $remaining[[Math]::Min($index, $remaining.Count - 1)] }
    Set-AttachedContextPaths -Paths $remaining -Select $next
    Update-Details
})

function Start-HandoffFromUi {
    $source = $script:handoffSource
    if (-not $source) { return }
    $workPath = $script:handoffWorkspace
    $targetAgent = [string]$uiAgent.SelectedItem
    $targetModel = Get-ModelSlug ([string]$uiModel.SelectedItem)
    $targetMode = [string]$uiMode.SelectedItem
    $targetEffort = [string]$uiEffort.SelectedItem
    $targetPersona = if ($uiPersona.Enabled) { [string]$uiPersona.SelectedItem } else { '' }
    $targetWeb = [string]$uiWeb.SelectedItem
    $note = [string]$uiPrompt.Text
    $statusChoice = [string]$uiHandoffStatus.SelectedItem
    $timing = [string]$uiHandoffTiming.SelectedItem
    $key = [string]$source.AgentId
    if ($script:plannedHandoffs.ContainsKey($key)) {
        [void][System.Windows.Forms.MessageBox]::Show($form, 'This source session already has a planned handoff. Cancel it from Live sessions before planning another.', 'Already planned')
        return
    }
    if ($timing -ne 'Hand off now' -and $statusChoice -ne 'Session writes it') {
        [void][System.Windows.Forms.MessageBox]::Show($form, 'A planned handoff needs the source session to write a fresh checkpoint. Choose Session writes it, or hand off now with a manual status.', 'Choose status method')
        return
    }
    if ($timing -ne 'Hand off now' -and $source.Permission -match 'read|plan') {
        [void][System.Windows.Forms.MessageBox]::Show($form, 'This read-only source session cannot write a checkpoint file. Hand off now with a manual status.', 'Read-only source')
        return
    }
    if ($timing -eq 'Automatic at 85% account use' -and $targetAgent -eq [string]$source.Agent) {
        $answer = [System.Windows.Forms.MessageBox]::Show($form,
            'The receiving agent uses the same account limit as the source. It may be blocked after the handoff. Continue?',
            'Same account limit', 'YesNo', 'Warning')
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    }
    if ($timing -eq 'Automatic at 85% account use' -and $source.Agent -eq 'Claude' -and
        -not $script:claudeUsageEnabled) {
        [void][System.Windows.Forms.MessageBox]::Show($form,
            'Claude account-limit polling is disabled in config.json. Choose Checkpoint at next safe point, or explicitly enable ClaudeAccountLimits before using automatic account-limit handoff.',
            'No automatic Claude limit measurement')
        return
    }
    $handoff = $null
    try {
        $handoff = New-HandoffFile -WorkingDirectory $workPath -FromAgent ([string]$source.Agent) `
            -FromModel ([string]$source.Model) -FromPermission ([string]$source.Permission) `
            -ToAgent $targetAgent -ToModel $targetModel -ToMode $targetMode -ToEffort $targetEffort -Note $note
        if ($timing -ne 'Hand off now') {
            $plan = [pscustomobject]@{
                Source = $source
                Handoff = $handoff
                Timing = $timing
                TargetAgent = $targetAgent
                TargetModel = $targetModel
                TargetMode = $targetMode
                TargetEffort = $targetEffort
                TargetPersona = $targetPersona
                TargetWeb = $targetWeb
                TargetHost = [string]$uiTerminalHost.SelectedItem
                Contexts = @(Get-AttachedContextPaths)
                Requested = $false
                RequestedAt = [datetime]::MinValue
                LastStatusStamp = ''
                LastRequestStatus = ''
                MissingPolls = 0
            }
            $script:plannedHandoffs[$key] = $plan
            if ($timing -eq 'Checkpoint at next safe point' -and -not (Request-PlannedCheckpoint -Plan $plan)) {
                $script:plannedHandoffs.Remove($key)
                Remove-HandoffFiles -Handoff $handoff
                $detail = Get-TabAgentReason ([string]$plan.LastRequestStatus)
                [void][System.Windows.Forms.MessageBox]::Show($form,
                    ('The source terminal could not receive the checkpoint request: {0}. No recipient was started.' -f $detail),
                    'Could not schedule checkpoint')
                return
            }
            Exit-HandoffMode
            Set-LauncherView 'live'
            $uiLiveSummary.Text = if ($timing -eq 'Automatic at 85% account use') {
                'Automatic handoff armed for {0}; waiting for a fresh 85% account measurement.' -f $source.Project
            } else { 'Checkpoint requested from {0}; waiting for the source to finish its current safe step.' -f $source.Project }
            return
        }
        $statusText = ''
        $statusSource = 'none'
        $manualReason = ''
        if ($statusChoice -eq 'Session writes it') {
            $request = Get-HandoffRequest -Handoff $handoff
            $sendStatus = Send-SessionCommand -Session $source -Command $request
            # Said in the status dialog, so a fallback to writing it by hand is
            # not unexplained.
            $manualReason = if ($sendStatus -ne 'sent') {
                Get-TabAgentReason $sendStatus
            } else {
                'it did not finish a complete status within 45 seconds'
            }
            if ($sendStatus -eq 'sent') {
                $started = Get-Date
                $lastStamp = ''
                while (((Get-Date) - $started).TotalSeconds -lt 45) {
                    [System.Windows.Forms.Application]::DoEvents()
                    $stamp = Get-HandoffStatusStamp -Path $handoff.StatusPath
                    if ($stamp -and $stamp -eq $lastStamp) {
                        $statusText = Read-HandoffStatus -Path $handoff.StatusPath
                        if (Test-HandoffStatusReady $statusText) { break }
                    }
                    $lastStamp = $stamp
                    Start-Sleep -Milliseconds 250
                }
            }
            if ($statusText -and (Test-HandoffStatusReady $statusText)) { $statusSource = 'agent' }
            else { $statusText = '' }
        }
        if (-not $statusText) {
            do {
                $statusText = Get-ManualHandoffStatus -Handoff $handoff -Reason $manualReason
                if ($null -eq $statusText) {
                    Remove-HandoffFiles -Handoff $handoff
                    return
                }
                if (Test-HandoffStatusEmpty $statusText) {
                    [void][System.Windows.Forms.MessageBox]::Show($form,
                        'Please write at least one concrete line before handing off.', 'Status is empty')
                }
            } while (Test-HandoffStatusEmpty $statusText)
            $statusSource = 'manual'
        }
        Complete-HandoffFile -Handoff $handoff -StatusSource $statusSource -StatusText $statusText
        $prompt = Get-HandoffPrompt -HandoffPath $handoff.Path -WorkingDirectory $workPath
        Start-AgentTerminal -SelectedAgent $targetAgent -WorkingDirectory $workPath `
            -ContextDirectories @(Get-AttachedContextPaths) -SelectedModel $targetModel -SelectedMode $targetMode `
            -StartMode $startNewLabel -OpeningPrompt $prompt -SelectedEffort $targetEffort `
            -SelectedPersona $targetPersona -SelectedWeb $targetWeb
        Exit-HandoffMode
        Set-LauncherView 'live'
    } catch {
        if ($script:plannedHandoffs.ContainsKey($key)) { [void]$script:plannedHandoffs.Remove($key) }
        if ($handoff) { Remove-HandoffFiles -Handoff $handoff }
        throw
    }
}

# Role is per session; it never overwrites saved Ordinary project settings.
$uiSessionRole.Add_SelectedIndexChanged({
    $ordinary = ([string]$uiSessionRole.SelectedItem -eq 'Ordinary')
    if (-not $script:handoffSource -and -not $script:suspendSessionPreference) {
        $script:lastSessionRole = [string]$uiSessionRole.SelectedItem
        Save-LauncherSettings
    }
    foreach ($control in @($uiMode, $uiStartMode, $uiPrompt, $uiPersona, $uiWeb, $advanced)) { $control.Enabled = $true }
    $uiRoleNote.Text = if ($ordinary) { '' } else { 'Delegation, tests and automatic repair' }
    Update-Details
})

$uiStart.Add_Click({
    try {
        if ([string]$uiSessionRole.SelectedItem -eq 'Orchestrator') {
            if ($script:handoffSource) { throw 'Orchestrator starts a new managed session. Choose Ordinary for an existing handoff.' }
            Import-OrchestratorEntry
            $orchestratorProject = Get-SelectedProjectPath
            $orchestratorContexts = @(Get-OrchestratorContextPaths -ProjectPath $orchestratorProject -Attached @(Get-AttachedContextPaths))
            $preview = Get-OrchestratorPreview -SelectedAgent ([string]$uiAgent.SelectedItem) -WorkingDirectory $orchestratorProject -AdapterPath $OrchestratorAdapter -Contexts $orchestratorContexts -Model (Get-ModelSlug ([string]$uiModel.SelectedItem)) -Start ([string]$uiStartMode.SelectedItem) -Prompt ([string]$uiPrompt.Text) -Effort ([string]$uiEffort.SelectedItem)
            $null = Start-OrchestratorTerminal $preview
            $script:lastAgent = [string]$uiAgent.SelectedItem
            $script:lastProject = $orchestratorProject
            Save-ProjectContexts
            Save-AgentModel
            Save-LauncherSettings
            $uiPrompt.Clear()
            return
        }
        if ($script:handoffSource) {
            Start-HandoffFromUi
            return
        }
        $workPath = Get-SelectedProjectPath
        $contexts = @(Get-AttachedContextPaths)
        $agentName = [string]$uiAgent.SelectedItem
        $modelName = Get-ModelSlug ([string]$uiModel.SelectedItem)
        $modeName  = [string]$uiMode.SelectedItem
        $startName = [string]$uiStartMode.SelectedItem
        $promptText = if ($uiPrompt.ReadOnly) { '' } else { [string]$uiPrompt.Text }
        $effortName = [string]$uiEffort.SelectedItem
        $personaName = if ($uiPersona.Enabled) { [string]$uiPersona.SelectedItem } else { '' }
        $webName = [string]$uiWeb.SelectedItem
        $preview = Get-LaunchPreview -SelectedAgent $agentName -WorkingDirectory $workPath -ContextDirectories $contexts -SelectedModel $modelName -SelectedMode $modeName -StartMode $startName -OpeningPrompt $promptText -SelectedEffort $effortName -SelectedPersona $personaName -SelectedWeb $webName

        # A second session in a folder that already has one is allowed without
        # asking. The one case that cannot work is resuming the very session
        # that is still open, so that is the only thing checked, at the moment
        # of launch rather than from a snapshot that goes stale.
        if ($preview.StartMode -eq 'Continue last') {
            $activeResume = @(Get-LiveAgentSessions) | Where-Object {
                $_.Agent -eq $preview.Agent -and (Test-LiveSessionProject $_ $workPath)
            } | Select-Object -First 1
            if ($activeResume) {
                [void][System.Windows.Forms.MessageBox]::Show(
                    $form,
                    ("A {0} session is already running in '{1}'.`r`n`r`nContinue last cannot open the same session twice. Switch to the existing terminal, or close it and try again." -f $activeResume.Agent, (Split-Path -Leaf $workPath)),
                    'Session already running',
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Warning
                )
                return
            }
        }
        $script:lastAgent      = $agentName
        $script:lastProject    = $workPath
        Save-ProjectContexts
        Save-ProjectMode
        Save-AgentModel
        Save-LauncherSettings
        Start-AgentTerminal -SelectedAgent $agentName -WorkingDirectory $workPath `
            -ContextDirectories $contexts -SelectedModel $modelName -SelectedMode $modeName `
            -StartMode $startName -OpeningPrompt $promptText `
            -SelectedEffort $effortName -SelectedPersona $personaName -SelectedWeb $webName `
            -SessionTitle ([string]$uiSessionTitle.Text)
        # The launcher stays open for another session. The opening prompt has
        # already been handed to the terminal, so do not leave it looking like
        # an unsent draft. A failed launch throws above and deliberately keeps it.
        $uiPrompt.Clear()
        $uiSessionTitle.Clear()
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'Cannot start agent')
    }
})

# ------------------------------------------------------------------ start ---

Update-Layout
Refresh-ProjectList -KeepSelected $script:lastProject
Load-ProjectContexts (Get-SelectedProjectPath)
$uiSessionRole.SelectedItem = $script:lastSessionRole
if ($loaded.LastTerminalHost -eq 'Herdr isolated') { $loaded.LastTerminalHost = 'Herdr' }
if ($loaded.LastTerminalHost -in @('Terminal','Herdr')) { $uiTerminalHost.SelectedItem = [string]$loaded.LastTerminalHost }
if ($script:lastAgent -and $uiAgent.Items.Contains($script:lastAgent)) { $uiAgent.SelectedItem = $script:lastAgent }
Load-AgentModel ([string]$uiAgent.SelectedItem)
Refresh-EffortChoices
Refresh-PersonaChoices
Update-Details
Set-LauncherView 'new'

[void]$form.ShowDialog()
Remove-TabAgentScript





















