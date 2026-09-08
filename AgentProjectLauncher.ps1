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
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
        private const int HTCLIENT = 1;
        private const int HTLEFT = 10, HTRIGHT = 11, HTTOP = 12;
        private const int HTTOPLEFT = 13, HTTOPRIGHT = 14, HTBOTTOM = 15;
        private const int HTBOTTOMLEFT = 16, HTBOTTOMRIGHT = 17;
        public bool VerticalResizeOnly { get { return true; } }

        public VerticalResizeForm() {
            SetStyle(ControlStyles.AllPaintingInWmPaint |
                     ControlStyles.OptimizedDoubleBuffer |
                     ControlStyles.ResizeRedraw, true);
        }

        protected override void WndProc(ref Message m) {
            base.WndProc(ref m);
            if (m.Msg != WM_NCHITTEST) return;
            int hit = m.Result.ToInt32();
            if (hit == HTLEFT || hit == HTRIGHT) m.Result = (IntPtr)HTCLIENT;
            else if (hit == HTTOPLEFT || hit == HTTOPRIGHT) m.Result = (IntPtr)HTTOP;
            else if (hit == HTBOTTOMLEFT || hit == HTBOTTOMRIGHT) m.Result = (IntPtr)HTBOTTOM;
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
$launcherDataRoot = Join-Path $env:LOCALAPPDATA 'AgentProjectLauncher'
$configPath = Join-Path $launcherDataRoot 'config.json'
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
$projectsRoot = $vaultRoot
$claudePath = if ($publicConfig -and $publicConfig.ClaudePath) { [string]$publicConfig.ClaudePath } else { '' }
$codexPath = if ($publicConfig -and $publicConfig.CodexPath) { [string]$publicConfig.CodexPath } else { '' }
$settingsPath = Join-Path $launcherDataRoot 'settings.json'
$script:claudeTranscriptByPid = @{}
$script:codexTranscriptByPid = @{}
$script:claudeAccountUsage = $null

# ---------------------------------------------------------------- helpers ---


function Test-SamePath {
    param([string]$Left, [string]$Right)
    if (-not $Left -or -not $Right) { return $false }
    return $Left.TrimEnd('\').Equals($Right.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)
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
        LastAgent      = ''; LastProject   = ''
        ProjectContexts = @{}; AgentModels = @{}; AgentModes = @{}; ProjectModes = @{}; ProjectWeb = @{}
    }
    if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) { return $empty }
    try {
        $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
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
    if (-not (Test-Path -LiteralPath $launcherDataRoot -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $launcherDataRoot -Force)
    }
    [ordered]@{
        hiddenProjects  = @($script:hiddenProjects | Sort-Object -Unique)
        savedProjects   = @($script:savedProjects  | Sort-Object -Unique)
        lastAgent       = [string]$script:lastAgent
        lastProject     = [string]$script:lastProject
        projectContexts = $contextMap
        projectModes    = $projectModeMap
        projectWeb      = $projectWebMap
        agentModels     = $modelMap
        agentModes      = $modeMap
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $settingsPath -Encoding UTF8
}

function Resolve-WorkspacePath {
    # A full path is taken as given, wherever it points - a second drive or a
    # UNC share is a legitimate place to work. The configured roots are only a
    # shorthand: a bare name is looked up inside them, and anything else has to
    # be spelled out in full.
    param([Parameter(Mandatory)][string]$Value, [switch]$AllowAnywhere)
    if ($Value -in @('Notes', 'Notes (root)')) { return $vaultRoot }
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
    foreach ($name in $instructionFiles) {
        $file = Join-Path $ProjectPath $name
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
        $present += $name
        $text = Get-Content -LiteralPath $file -Raw -ErrorAction SilentlyContinue
        if (-not $text) { continue }
        foreach ($match in [regex]::Matches($text, '(?im)^\s*(?:[-*]\s+)?(?:Vault notes|Notes):\s*`?([^`\r\n]+)`?\s*$')) {
            $reference = $match.Groups[1].Value.Trim().TrimEnd('.', '`', ')', ',', '/', '\')
            $full = [Environment]::ExpandEnvironmentVariables($reference -replace '/', '\')
            if (-not [System.IO.Path]::IsPathRooted($full)) { $full = Join-Path $vaultRoot $full }
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
            'Ask me'                   { return @('--permission-mode', 'manual') }
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
    if (Test-SamePath $Path $vaultRoot) { return 'Notes (root)' }
    if ($Path.StartsWith($vaultRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        return 'Notes\' + $Path.Substring($vaultRoot.Length).TrimStart('\')
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
    if ($Tokens -le 0) { return '—' }
    $short = if ($Tokens -ge 1000000) { '{0:0.0}m' -f ($Tokens / 1000000) } else { '{0:0}k' -f ($Tokens / 1000) }
    if ($Window -gt 0) {
        $percent = [math]::Min(999, [math]::Round(($Tokens * 100.0) / $Window))
        return '{0} · {1}%' -f $short, $percent
    }
    return $short
}

function Get-ContextHealth {
    param([long]$Tokens, [long]$Window)
    if ($Tokens -le 0 -or $Window -le 0) { return '—' }
    $percent = ($Tokens * 100.0) / $Window
    if ($percent -ge 80) { return 'Compact' }
    if ($percent -ge 60) { return 'Watch' }
    return 'OK'
}

function Get-LiveLaunchDetails {
    param([ValidateSet('Claude', 'Codex')][string]$Agent, [string]$CommandLine)

    $permission = 'Default'
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
    }
}

function Get-ClaudeTranscriptModel {
    param(
        [string]$Workspace,
        [string]$Project,
        [datetime]$Started,
        [string]$CommandLine,
        [int]$ProcessId
    )

    # Claude changes /model inside the running process, so its command line
    # only tells us the launch model. The transcript records the model on each
    # assistant entry. Read only those metadata fields, never message content.
    $workspacePath = $Workspace
    if (-not $workspacePath -and $Project -and $Project -ne '(external)') {
        if ($Project -eq 'Notes') {
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
    if (-not $workspacePath) { return $null }

    $projectKey = $workspacePath -replace '[:\\/]', '-'
    $transcriptDirectory = Join-Path (Join-Path $env:USERPROFILE '.claude\projects') $projectKey
    if (-not (Test-Path -LiteralPath $transcriptDirectory -PathType Container)) { return $null }

    $transcript = $null
    $pidKey = [string]$ProcessId
    if ($script:claudeTranscriptByPid.ContainsKey($pidKey)) {
        $remembered = [string]$script:claudeTranscriptByPid[$pidKey]
        if (Test-Path -LiteralPath $remembered -PathType Leaf) {
            $transcript = Get-Item -LiteralPath $remembered
        }
    }

    if (-not $transcript) {
        $files = @(Get-ChildItem -LiteralPath $transcriptDirectory -File -Filter '*.jsonl' -ErrorAction SilentlyContinue)
        if ($files.Count -eq 0) { return $null }

        # An explicit resume exposes the session id. A new session writes its
        # transcript once the first message is sent, so the file this process
        # created is the one that appeared at or after it started.
        $sessionId = ''
        if ($CommandLine -match '(?i)\b([0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12})\b') { $sessionId = $Matches[1] }
        $certain = $false
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
        # A guess is remembered only until the next refresh. Caching it would
        # pin a session that had not written its transcript yet to whichever
        # file happened to be newest when the list was first opened.
        if ($certain) { $script:claudeTranscriptByPid[$pidKey] = $transcript.FullName }
    }

    # Transcript lines can contain multi-megabyte tool results. Get-Content
    # -Tail plus ConvertFrom-Json loads all of that onto the UI thread and can
    # make WinForms appear hung. Read a bounded byte window from the end and
    # inspect only the small metadata prefix of complete JSONL records.
    $activeModel = ''
    [long]$contextTokens = 0
    $usageDisplay = '—'
    $usageDetail = 'Run /usage in this Claude session, then Refresh, to update limit usage.'
    $usageMeasuredAt = [datetime]::MinValue
    $pendingLocalCommand = ''
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
                # The record's own '"type":"assistant"' is written after the
                # message content, so on any turn longer than the prefix it is
                # out of reach. The message header is not: role and model sit in
                # the first few hundred bytes. Subagent turns carry their own
                # context and must not be mistaken for the session's.
                if ($prefix -match '"role"\s*:\s*"assistant"' -and
                    $prefix -notmatch '"isSidechain"\s*:\s*true' -and
                    $prefix -match '"model"\s*:\s*"(claude-[^"\\]+)"') {
                    $activeModel = $Matches[1]
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
    # Claude 5's CLI context window is one million tokens. The transcript's
    # usage total is the same pre-compaction token count shown by /context.
    [long]$contextWindow = 1000000
    return [pscustomobject]@{
        Display = Get-CompactModelName $activeModel
        Exact   = $activeModel
        ContextTokens = $contextTokens
        ContextWindow = $contextWindow
        UsageDisplay = $usageDisplay
        UsageDetail  = $usageDetail
        UsageMeasuredAt = $usageMeasuredAt
    }
}

function Get-ClaudeAccountUsage {
    # No supported public API currently provides Claude account limits.
    # Transcript context usage remains available in Live sessions.
    return $null
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
    if (-not (Test-Path -LiteralPath $dayDirectory -PathType Container)) { return $null }

    $transcript = $null
    $pidKey = [string]$ProcessId
    if ($script:codexTranscriptByPid.ContainsKey($pidKey)) {
        $remembered = [string]$script:codexTranscriptByPid[$pidKey]
        if (Test-Path -LiteralPath $remembered -PathType Leaf) { $transcript = Get-Item -LiteralPath $remembered }
    }

    if (-not $transcript) {
        $files = @(Get-ChildItem -LiteralPath $dayDirectory -File -Filter 'rollout-*.jsonl' -ErrorAction SilentlyContinue)
        $sessionId = ''
        if ($CommandLine -match '(?i)\b([0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12})\b') { $sessionId = $Matches[1] }
        if ($sessionId) {
            $transcript = $files | Where-Object { $_.BaseName -like ('*-' + $sessionId) } | Select-Object -First 1
        }
        if (-not $transcript) {
            $workspacePath = $Workspace
            if (-not $workspacePath -and $Project -and $Project -ne '(external)') {
                foreach ($root in @($codeProjectsRoot, $projectsRoot)) {
                    $candidate = Join-Path $root $Project
                    if (Test-Path -LiteralPath $candidate -PathType Container) { $workspacePath = $candidate; break }
                }
            }
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
                    $isCli = ([string]$meta.payload.source -eq 'cli')
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
    [long]$contextTokens = 0
    [long]$contextWindow = 0
    $usageDisplay = '—'
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
                    } elseif ($entry.type -eq 'event_msg' -and $entry.payload.type -eq 'token_count' -and $entry.payload.info) {
                        $contextTokens = [long]$entry.payload.info.last_token_usage.total_tokens
                        $contextWindow = [long]$entry.payload.info.model_context_window
                        if ($entry.payload.rate_limits) {
                            $primary = $entry.payload.rate_limits.primary
                            $secondary = $entry.payload.rate_limits.secondary
                            if ($primary -and $secondary) {
                                $usageDisplay = '{0:0}/{1:0}%' -f [double]$primary.used_percent, [double]$secondary.used_percent
                                $primaryReset = [DateTimeOffset]::FromUnixTimeSeconds([long]$primary.resets_at).LocalDateTime
                                $secondaryReset = [DateTimeOffset]::FromUnixTimeSeconds([long]$secondary.resets_at).LocalDateTime
                                $usageDetail = @(
                                    ('{0}h window: {1:0}% used; resets {2:g}' -f ([double]$primary.window_minutes / 60), [double]$primary.used_percent, $primaryReset),
                                    ('{0}d window: {1:0}% used; resets {2:g}' -f ([double]$secondary.window_minutes / 1440), [double]$secondary.used_percent, $secondaryReset)
                                ) -join "`r`n"
                                $usageMeasuredAt = [datetime]$entry.timestamp
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
    return [pscustomobject]@{
        Display = Get-CompactModelName $activeModel
        Exact   = $activeModel
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
        $processFilter = "Name='claude.exe' OR Name='codex.exe' OR Name='powershell.exe' OR Name='cmd.exe' OR Name='node.exe'"
        $processRows = @(Get-CimInstance Win32_Process -Filter $processFilter -ErrorAction Stop)
        $byId = @{}
        foreach ($row in $processRows) { $byId[[int]$row.ProcessId] = $row }

        $agentRows = @($processRows | Where-Object {
            $name = [string]$_.Name
            $commandLine = [string]$_.CommandLine
            ($name -ieq 'claude.exe') -or
            (($name -ieq 'codex.exe') -and
             ($commandLine -notmatch '(?i)\bapp-server\b') -and
             ($commandLine -notmatch '(?i)\bsandbox\b'))
        })

        $sessions = @()
        foreach ($agentRow in $agentRows) {
            $terminal = $null
            $cursor = $agentRow
            $seen = @{}
            while ($cursor -and -not $seen.ContainsKey([int]$cursor.ProcessId)) {
                $seen[[int]$cursor.ProcessId] = $true
                if ([string]$cursor.Name -ieq 'powershell.exe') { $terminal = $cursor; break }
                $parentId = [int]$cursor.ParentProcessId
                $cursor = if ($byId.ContainsKey($parentId)) { $byId[$parentId] } else { $null }
            }

            # This page is for terminal sessions. App-server and orphaned helper
            # processes are deliberately excluded.
            if (-not $terminal) { continue }
            $terminalCommand = [string]$terminal.CommandLine
            $workspace = ''
            if ($terminalCommand -match "(?i)AGENT_LAUNCHER_WORKSPACE\s*=\s*'((?:''|[^'])*)'") {
                $workspace = $Matches[1] -replace "''", "'"
            }
            $windowTitle = ''
            if ($terminalCommand -match "(?i)WindowTitle\s*=\s*'((?:''|[^'])*)'") {
                $windowTitle = $Matches[1] -replace "''", "'"
            }
            $project = if ($workspace) { Split-Path -Leaf $workspace } elseif ($windowTitle) {
                ($windowTitle -split '\s{2}\+\s{2}', 2)[0]
            } else { '(external)' }

            $agentCommand = [string]$agentRow.CommandLine
            $model = '(default)'
            if ($agentCommand -match '(?i)[''"]?--model[''"]?\s+[''"]?([^''"\s]+)') { $model = $Matches[1] }
            $agentName = if ([string]$agentRow.Name -ieq 'claude.exe') { 'Claude' } else { 'Codex' }
            $currentModel = Get-CompactModelName $model
            $modelDetail = $model
            $modelSource = 'launch command'
            [long]$contextTokens = 0
            [long]$contextWindow = 0
            $usageDisplay = '—'
            $usageDetail = 'No usage-limit measurement is available.'
            $usageMeasuredAt = [datetime]::MinValue
            if ($agentName -eq 'Claude') {
                $transcriptState = Get-ClaudeTranscriptModel -Workspace $workspace -Project $project `
                    -Started ([datetime]$agentRow.CreationDate) -CommandLine $agentCommand -ProcessId ([int]$agentRow.ProcessId)
                if ($transcriptState) {
                    $currentModel = $transcriptState.Display
                    $modelDetail = $transcriptState.Exact
                    $modelSource = 'active Claude session'
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
            $launchDetails = Get-LiveLaunchDetails -Agent $agentName -CommandLine $agentCommand
            $sessions += [pscustomobject]@{
                Agent       = $agentName
                Project     = $project
                Workspace   = $workspace
                WindowTitle = $windowTitle
                StartModel  = $model
                Model       = $currentModel
                ModelDetail = $modelDetail
                ModelSource = $modelSource
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
            }
        }
        # Limits are account-wide, not session-specific. An idle transcript can
        # contain an old snapshot, so show the freshest measurement on every
        # live row for the same agent.
        foreach ($accountAgent in @('Claude', 'Codex')) {
            $freshest = $sessions | Where-Object {
                $_.Agent -eq $accountAgent -and $_.UsageDisplay -ne '—' -and $_.UsageMeasuredAt -gt [datetime]::MinValue
            } | Sort-Object UsageMeasuredAt -Descending | Select-Object -First 1
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
        [string]$SelectedWeb = ''
    )
    $preview = Get-LaunchPreview -SelectedAgent $SelectedAgent -WorkingDirectory $WorkingDirectory -ContextDirectories $ContextDirectories -SelectedModel $SelectedModel -SelectedMode $SelectedMode -StartMode $StartMode -OpeningPrompt $OpeningPrompt -SelectedEffort $SelectedEffort -SelectedPersona $SelectedPersona -SelectedWeb $SelectedWeb
    $activeTerminal = Find-ActiveAgentTerminal $preview
    if ($activeTerminal) {
        throw ("The latest {0} session for '{1}' is already open in another terminal. " +
               "Switch to the existing '{1}' window, or close it before choosing Continue last.") -f
              $preview.Agent, $preview.TerminalTitle
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
    Start-Process -FilePath "$PSHOME\powershell.exe" -WorkingDirectory $preview.WorkingDirectory `
        -ArgumentList @('-NoLogo', '-NoExit', '-Command', $command)
}

# ------------------------------------------------------- command-line mode ---

if ($Agent -or $Project -or $Context -or $Model -or $Mode -or $Start -or $Prompt -or $Effort -or $Persona -or $Web -or $DryRun) {
    if (-not $Agent)   { throw 'Direct or dry-run mode requires -Agent.' }
    if (-not $Project) { throw 'Direct or dry-run mode requires -Project.' }
    $workPath = Resolve-WorkspacePath $Project
    $contextPaths = @()
    if ($Context) { $contextPaths = @($Context | ForEach-Object { Resolve-WorkspacePath $_ -AllowAnywhere }) }
    if ($DryRun) {
        Get-LaunchPreview -SelectedAgent $Agent -WorkingDirectory $workPath -ContextDirectories $contextPaths -SelectedModel $Model -SelectedMode $Mode -StartMode $Start -OpeningPrompt $Prompt -SelectedEffort $Effort -SelectedPersona $Persona -SelectedWeb $Web | ConvertTo-Json -Depth 5
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

$form = New-Object Launcher.VerticalResizeForm
$form.Text            = 'Start an agent session'
$form.StartPosition   = 'CenterScreen'
$form.FormBorderStyle = 'Sizable'
$form.MaximizeBox     = $false
$form.MinimizeBox     = $true
$form.ClientSize      = New-Object System.Drawing.Size(820, 504)
$form.MinimumSize     = $form.Size
$form.MaximumSize     = New-Object System.Drawing.Size($form.Width, [System.Windows.Forms.SystemInformation]::MaxWindowTrackSize.Height)
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

# Returning an array from a function unrolls it, so an empty result arrives as
# $null and $null.Count throws under StrictMode. Every caller wraps in @().
function Get-PickerSubdirectories {
    param([string]$Path)
    try {
        return @(Get-ChildItem -LiteralPath $Path -Directory -ErrorAction Stop |
            Where-Object { -not $_.Name.StartsWith('.') -and -not ($_.Attributes -band [System.IO.FileAttributes]::Hidden) } |
            Sort-Object Name)
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
        try { $reachable = Test-Path -LiteralPath $share -PathType Container } catch { }
        if ($reachable) { $seen += $share }
    }
    return @($seen)
}

function Get-PickerDriveRoots {
    $roots = @()
    foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
        if (-not $drive.IsReady) { continue }
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
    # the real contents the first time the node is opened.
    if (@(Get-PickerSubdirectories $Path).Count -gt 0) {
        [void]$node.Nodes.Add((New-Object System.Windows.Forms.TreeNode '...'))
    }
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

$panelW = 788
$edgeL  = 16
$edgeR  = 772

$uiNewTab  = New-ThemeButton $form 'New session'   16 10 146 $theme.Section 1
$uiLiveTab = New-ThemeButton $form 'Live sessions' 170 10 162 $theme.Label 1
$uiBrandWordmark = New-RainbowWordmark $form 667 10
$uiBrandWordmark.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right

$panel = New-ThemePanel $form 16 46 $panelW 444 -Bordered
$panel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right

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

$uiProject = New-ThemeCombo $panel $edgeL 44 504
$uiProjectBrowse = New-ThemeButton $panel 'Browse...' 536 44 124 $theme.Head 1
$uiProjectRemove = New-ThemeButton $panel 'Remove'    668 44 104 $theme.Head 1

$uiProjectPath = New-ThemeText $panel '' $edgeL 78 $theme.Muted 756

$uiVaultLink = New-ThemeText $panel '' $edgeL 106 $theme.Muted 600
$uiVaultLinkSet = New-ThemeButton $panel 'Link...' 668 104 104 $theme.Head 1
Set-RowTip $uiVaultLinkSet $help.VaultLink

[void](New-ThemeRule $panel 138)
[void](New-ThemeText $panel '# Agent configuration' $edgeL 152 $theme.Section 400)

[void](New-ThemeText $panel 'Agent' $edgeL 180 $theme.Label 170)
$uiAgent = New-ThemeCombo $panel $edgeL 202 176
[void]$uiAgent.Items.Add('Claude')
[void]$uiAgent.Items.Add('Codex')
$uiAgent.SelectedIndex = 0

# A real dropdown list, so clicking anywhere in the box opens it. Typing a model
# the list does not have is still possible via the 'Other...' entry.
[void](New-ThemeText $panel 'Model' 196 180 $theme.Label 180)
$uiModel = New-ThemeCombo $panel 196 202 188

# The '[?]' marks belong to Advanced options; out here the rows are self
# explanatory, so they carry the hover text without the clutter.
$uiEffortLabel = New-ThemeText $panel 'Effort' 388 180 $theme.Label 150
Set-RowTip $uiEffortLabel $help.Effort
$uiEffort = New-ThemeCombo $panel 388 202 152
Set-RowTip $uiEffort $help.Effort

$uiModeLabel = New-ThemeText $panel 'Permissions' 544 180 $theme.Label 228
Set-RowTip $uiModeLabel $help.Permissions
$uiMode = New-ThemeCombo $panel 544 202 228
foreach ($choice in $modeChoices) { [void]$uiMode.Items.Add($choice) }
$uiMode.SelectedItem = $modeDefaultLabel
Set-RowTip $uiMode $help.Permissions

[void](New-ThemeRule $panel 240)
[void](New-ThemeText $panel '# Session' $edgeL 254 $theme.Section 300)

$uiStartLabel = New-ThemeText $panel 'Start' $edgeL 282 $theme.Label 170
Set-RowTip $uiStartLabel $help.Start
$uiStartMode = New-ThemeCombo $panel $edgeL 304 176
foreach ($choice in $startChoices) { [void]$uiStartMode.Items.Add($choice) }
$uiStartMode.SelectedItem = $startNewLabel

$uiPromptLabel = New-ThemeText $panel '' 196 282 $theme.Label 400
Set-RowTip $uiPromptLabel $help.Prompt
$uiPrompt = New-ThemeTextBox $panel 196 304 576

# ------------------------------------------------------- advanced options ---
# Everything here is set once for a project and then left alone, so it stays
# folded away. The disclosure is the only thing that resizes the window now.

$uiAdvancedToggle = New-ThemeText $panel ('{0} Advanced options' -f [char]0x25B8) $edgeL 342 $theme.Label 300
$uiAdvancedToggle.Cursor = [System.Windows.Forms.Cursors]::Hand

$advanced = New-ThemePanel $panel 1 370 ($panelW - 2) 158
$advanced.Visible = $false

# Scope comes first because it changes what the whole session can work on.
[void](New-ThemeHelpText $advanced 'Also in scope' 15 4 $theme.Label 400 $help.Scope)
$uiContext = New-ThemeCombo $advanced 15 30 498
$uiContextAdd = New-ThemeButton $advanced '+ Folder' 529 30 130 $theme.Head 1
Set-RowTip $uiContextAdd $help.Scope
$uiContextRemove = New-ThemeButton $advanced 'Remove' 667 30 104 $theme.Head 1
$uiContextPath = New-ThemeText $advanced '' 15 62 $theme.Muted ($edgeR - $edgeL)

$uiPersonaLabel = New-ThemeHelpText $advanced 'Subagent persona' 15 90 $theme.Label 260 $help.Persona
$uiPersona = New-ThemeCombo $advanced 15 112 240

[void](New-ThemeHelpText $advanced 'Internet access' 290 90 $theme.Label 260 $help.Web)
$uiWeb = New-ThemeCombo $advanced 290 112 200
foreach ($choice in $webChoices) { [void]$uiWeb.Items.Add($choice) }
$uiWeb.SelectedItem = $webDefaultLabel
Set-RowTip $uiWeb $help.Web

# ---------------------------------------------------------- live sessions ---

$livePanel = New-ThemePanel $form 16 46 $panelW 380 -Bordered
$livePanel.Visible = $false
$livePanel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
[void](New-ThemeText $livePanel '# Live terminal sessions' $edgeL 16 $theme.Section 400)
$uiLiveCompact = New-ThemeButton $livePanel 'Compact all' 494 12 146 $theme.Head 1
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
$uiLiveRefresh = New-ThemeButton $livePanel 'Refresh' 648 12 124 $theme.Head 1
$uiLiveRefresh.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
[void](New-ThemeText $livePanel 'Context usage, limits and permissions. Hover for detail, click a session for its actions.' $edgeL 44 $theme.Muted 756)

# Context carries its own health: green below 60%, amber from 60%, red from 80%.
# A separate column only restated what the colour already says.
[void](New-ThemeText $livePanel 'Agent'   16 76 $theme.Label 64)
[void](New-ThemeText $livePanel 'Project' 94 76 $theme.Label 200)
[void](New-ThemeText $livePanel 'Model' 304 76 $theme.Label 125)
[void](New-ThemeText $livePanel 'Context' 432 76 $theme.Label 115)
[void](New-ThemeText $livePanel 'Limits' 551 76 $theme.Label 95)
[void](New-ThemeText $livePanel 'Permissions' 650 76 $theme.Label 100)
[void](New-ThemeRule $livePanel 102)

$uiLiveRows = New-Object Launcher.BufferedPanel
$uiLiveRows.Location = New-Object System.Drawing.Point(16, 108)
$uiLiveRows.Size = New-Object System.Drawing.Size(756, 224)
$uiLiveRows.BackColor = $theme.Panel
$uiLiveRows.Font = $fontBase
$uiLiveRows.AutoScroll = $true
$uiLiveRows.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$livePanel.Controls.Add($uiLiveRows)
$uiLiveSummary = New-ThemeText $livePanel '' 16 342 $theme.Muted 620
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

# Start and Cancel are anchored to the bottom edge, so the form has to be
# resized before they are moved: setting Top first and growing the form after
# applies the height change twice and drops them below the visible area.
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
$uiStart.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
$uiCancel.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
$uiCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
$form.AcceptButton = $uiStart
$form.CancelButton = $uiCancel
# Opening on a focused dropdown means a stray scroll changes the work folder.
$form.Add_Shown({
    # Build and paint the native child controls once while transparent. This
    # avoids their temporary white system-theme rectangles on the first frame.
    $form.Refresh()
    $form.Opacity = 1
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

# ------------------------------------------------------------------ state ---

$loaded = Get-LauncherSettings
$script:hiddenProjects = @($loaded.HiddenProjects)

$script:savedProjects  = @($loaded.SavedProjects)

$script:lastAgent      = [string]$loaded.LastAgent
$script:lastProject    = [string]$loaded.LastProject
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
        $candidates += [pscustomobject]@{ Display = 'Notes'; Path = $vaultRoot }
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
        if (-not (Test-Path -LiteralPath $saved -PathType Container)) { continue }
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
        if (-not (Test-Path -LiteralPath $path -PathType Container)) { continue }
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
            $looksClaude = ($name -match '(?i)Claude|[✳✻✢]')
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
        # Two indistinguishable tabs are not safe to guess between. New Codex
        # sessions have a >_ prefix, which removes this ambiguity.
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
    Start-Sleep -Milliseconds 250
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
    param([Parameter(Mandatory)]$Session, [string]$Command = '')

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
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$Command)
    return (Invoke-TabAgent -Session $Session -Command $Command)
}

# One wording for a failed hand-off, so the row menu and Compact all cannot
# drift apart.
function Get-TabAgentReason {
    param([string]$Status)
    switch ($Status) {
        'ambiguous' { 'two tabs look identical' }
        'notfound'  { 'tab not found' }
        'focus'     { 'window would not come forward' }
        'moved'     { 'focus moved away mid-command, left unsent' }
        default     { 'the tab helper did not answer' }
    }
}

function Get-SessionName {
    param($Session)
    if ($Session.Project) { return [string]$Session.Project }
    return '(unknown)'
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
$script:menuCompact = $script:sessionMenu.Items.Add('Compact this session')
$script:menuCompact.ForeColor = $theme.Head

function Show-SessionMenu {
    param([Parameter(Mandatory)]$Session)
    $script:menuSession = $Session
    $script:menuHeader.Text = '{0}  {1}' -f $Session.Agent, (Get-SessionName $Session)
    $script:sessionMenu.Show([System.Windows.Forms.Cursor]::Position)
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
    $status = Invoke-TabAgent -Session $session
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

function Refresh-LiveSessions {
    param([switch]$RefreshAccountUsage)
    if ($RefreshAccountUsage) {
        $uiLiveSummary.Text = 'Refreshing sessions and account limits...'
        [System.Windows.Forms.Application]::DoEvents()
    }
    $script:liveSessions = @(Get-LiveAgentSessions)
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
            $agentLabel = New-ThemeText $row $session.Agent 0 $y $theme.Head 64 $fontBase
            $projectText = if ($session.Project) { $session.Project } else { '(unknown)' }
            $projectLabel = New-ThemeText $row $projectText 78 $y $theme.Head 200 $fontBase
            $modelLabel = New-ThemeText $row $session.Model 288 $y $theme.Value 125 $fontBase
            Set-RowTip $modelLabel ('{0} ({1})' -f $session.ModelDetail, $session.ModelSource)
            # The health reading is the colour of the number now, not a word in a
            # column of its own.
            $contextColor = switch ($session.ContextHealth) {
                'Compact' { $theme.Danger }
                'Watch'   { $theme.Warning }
                'OK'      { $theme.Value }
                default   { $theme.Muted }
            }
            $contextLabel = New-ThemeText $row $session.ContextDisplay 416 $y $contextColor 115 $fontBase
            $contextTip = if ($session.ContextTokens -gt 0 -and $session.ContextWindow -gt 0) {
                '{0:N0} of {1:N0} tokens currently used.{2}{2}Green below 60%, amber from 60%, red from 80%.' -f
                    $session.ContextTokens, $session.ContextWindow, "`r`n"
            } elseif ($session.ContextTokens -gt 0) {
                '{0:N0} tokens currently used. Claude does not record the context-window limit here.' -f $session.ContextTokens
            } else { 'No token measurement has been written yet.' }
            Set-RowTip $contextLabel $contextTip
            $usageLabel = New-ThemeText $row $session.UsageDisplay 535 $y $theme.Head 95 $fontBase
            Set-RowTip $usageLabel $session.UsageDetail
            # Keep the right edge inside the viewport even when the vertical
            # scrollbar is present; horizontal scrolling is never needed here.
            $permissionLabel = New-ThemeText $row $session.Permission 634 $y $theme.Head 100 $fontBase
            Set-RowTip $permissionLabel ('Launch permission mode: ' + $session.Permission)
            $projectDetails = @()
            if ($session.Workspace) { $projectDetails += $session.Workspace }
            $projectDetails += ('Started {0:g}' -f $session.Started)
            $projectDetails += ('Agent PID {0}; terminal PID {1}' -f $session.AgentId, $session.TerminalId)
            Set-RowTip $projectLabel ($projectDetails -join "`r`n")

            # Every label as well as the row itself, or the pointer falls
            # through the gaps between them. Which row is being pointed at comes
            # from the sender, so all rows share one set of handlers.
            foreach ($target in (@($row) + @($row.Controls))) {
                $target.Add_MouseEnter($script:rowEnter)
                $target.Add_MouseLeave($script:rowLeave)
                $target.Add_Click($script:rowClick)
            }

            $rowIndex++
        }
    }
    $contentHeight = [Math]::Max(0, 8 + ($script:liveSessions.Count * 30))
    $uiLiveRows.AutoScrollMinSize = New-Object System.Drawing.Size(0, $contentHeight)
    $uiLiveRows.HorizontalScroll.Enabled = $false
    $uiLiveRows.HorizontalScroll.Visible = $false
    $uiLiveRows.ResumeLayout()
    $uiLiveSummary.Text = if ($script:liveSessions.Count -eq 1) { '1 live terminal session' } else {
        '{0} live terminal sessions' -f $script:liveSessions.Count
    }
    Set-ThemeButtonAvailable $uiLiveCompact ($script:liveSessions.Count -gt 0)
}

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
        'Each terminal is brought to the front in turn, so leave the mouse and',
        'keyboard alone until it finishes. Anything already typed but unsent in a',
        'session gets sent along with the command.'
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
        $uiLiveRefresh.Focus()
    } else {
        $form.AcceptButton = $uiStart
        Update-Layout
        $uiStart.Focus()
    }
}

function Update-Details {
    $workPath = Get-SelectedProjectPath
    $uiProjectRemove.Enabled = [bool]$workPath

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
    $uiProjectPath.Text = if ($workPath) { 'Opens in: ' + $workPath + $scopeNote } else { 'Opens in: -' }

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
    $resuming = ([string]$uiStartMode.SelectedItem -ne $startNewLabel)
    $promptBlocked = $resuming -and ([string]$uiAgent.SelectedItem -eq 'Codex')
    # ReadOnly rather than disabled: a disabled TextBox repaints itself in the
    # system grey and ignores BackColor, which would punch a light hole in the row.
    $uiPrompt.ReadOnly = $promptBlocked
    $uiPrompt.ForeColor = if ($promptBlocked) { $theme.Muted } else { $theme.Value }
    $uiPromptLabel.Text = if ($promptBlocked) { 'First message (not available when resuming Codex)' } else { 'First message (optional)' }

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
$vaultLinePattern = '(?i)^\s*(?:[-*]\s+)?Vault notes:\s*\x60?[^\x60]+\x60?\s*\.?\s*$'

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
        Write-InstructionLines $claudeFile @("# $projectName — Claude Context", '',
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

$script:chosenAgent = $null
$script:chosenProject = $null
$script:chosenContexts = @()
$script:chosenModel = ''
$script:chosenMode = ''
$script:chosenStart = ''
$script:chosenPrompt = ''
$script:chosenEffort = ''
$script:chosenPersona = ''
$script:chosenWeb = ''

$uiStart.Add_Click({
    try {
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

        # Check at the moment of launch instead of decorating the project list
        # from a snapshot that becomes stale when a terminal is closed.
        $liveNow = @(Get-LiveAgentSessions)
        $sameFolder = @($liveNow | Where-Object { Test-LiveSessionProject $_ $workPath })
        if ($sameFolder.Count -gt 0) {
            $activeResume = $null
            if ($preview.StartMode -eq 'Continue last') {
                $activeResume = $sameFolder | Where-Object { $_.Agent -eq $preview.Agent } | Select-Object -First 1
            }
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

            $sessionLines = @($sameFolder | ForEach-Object {
                $modelText = if ($_.Model) { ' — ' + $_.Model } else { '' }
                '• ' + $_.Agent + $modelText
            }) -join "`r`n"
            $answer = [System.Windows.Forms.MessageBox]::Show(
                $form,
                ("There is already an active session in '{0}':`r`n`r`n{1}`r`n`r`nStart another session in the same folder?" -f (Split-Path -Leaf $workPath), $sessionLines),
                'Session already running',
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }
        $script:chosenAgent    = $agentName
        $script:chosenProject  = $workPath
        $script:chosenContexts = $contexts
        $script:chosenModel    = $modelName
        $script:chosenMode     = $modeName
        $script:chosenStart    = $startName
        $script:chosenPrompt   = $promptText
        $script:chosenEffort   = $effortName
        $script:chosenPersona  = $personaName
        $script:chosenWeb      = $webName
        $script:lastAgent      = $agentName
        $script:lastProject    = $workPath
        Save-ProjectContexts
        Save-ProjectMode
        Save-AgentModel
        Save-LauncherSettings
        $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $form.Close()
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'Cannot start agent')
    }
})

# ------------------------------------------------------------------ start ---

Update-Layout
Refresh-ProjectList -KeepSelected $script:lastProject
Load-ProjectContexts (Get-SelectedProjectPath)
if ($script:lastAgent -and $uiAgent.Items.Contains($script:lastAgent)) { $uiAgent.SelectedItem = $script:lastAgent }
Load-AgentModel ([string]$uiAgent.SelectedItem)
Refresh-EffortChoices
Refresh-PersonaChoices
Update-Details
Set-LauncherView 'new'

$dialogResult = $form.ShowDialog()
Remove-TabAgentScript

if ($dialogResult -eq [System.Windows.Forms.DialogResult]::OK) {
    Start-AgentTerminal -SelectedAgent $script:chosenAgent -WorkingDirectory $script:chosenProject `
        -ContextDirectories $script:chosenContexts -SelectedModel $script:chosenModel -SelectedMode $script:chosenMode `
        -StartMode $script:chosenStart -OpeningPrompt $script:chosenPrompt `
        -SelectedEffort $script:chosenEffort -SelectedPersona $script:chosenPersona -SelectedWeb $script:chosenWeb
}























