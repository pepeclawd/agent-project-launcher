# Optional private adapter. Ordinary sessions never invoke its controller.
if (-not ('Launcher.OrchestratorOutput' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Threading.Tasks;
namespace Launcher {
    public static class OrchestratorOutput {
        public static async Task<string> Read(StreamReader reader) {
            var text = new StringBuilder();
            var buffer = new char[4096];
            int count;
            while ((count = await reader.ReadAsync(buffer, 0, buffer.Length).ConfigureAwait(false)) != 0) {
                if (text.Length + count > 65536) throw new InvalidDataException("Adapter output exceeds 64 KB.");
                text.Append(buffer, 0, count);
            }
            return text.ToString();
        }
    }
}
'@
}

function ConvertTo-OrchestratorArgument {
    param([AllowEmptyString()][string]$Value)
    '"' + [regex]::Replace(([regex]::Replace($Value, '(\\*)"', '$1$1\"')), '(\\+)$', '$1$1') + '"'
}

function Resolve-OrchestratorAdapterPath {
    param([string]$ExplicitPath)
    if ($ExplicitPath) { return $ExplicitPath }
    if ($env:AGENT_LAUNCHER_ORCHESTRATOR_ADAPTER) { return $env:AGENT_LAUNCHER_ORCHESTRATOR_ADAPTER }
    return (Join-Path $env:LOCALAPPDATA 'AgentProjectLauncher\orchestrator-adapter.json')
}

function Get-OrchestratorPreview {
    param([string]$SelectedAgent, [string]$WorkingDirectory, [string]$AdapterPath,
        [string[]]$Contexts, [string]$Model, [string]$Mode, [string]$Start,
        [string]$Prompt, [string]$Effort, [string]$Persona, [string]$Web, [string]$Handoff)
    if ($Mode -or $Persona -or $Web -or $Handoff -or ($Start -and $Start -notin @('New session','Continue last'))) {
        throw 'Orchestrator supports New session or Continue last managed workflow. Permission, persona, web, handoff and Pick a session overrides are unavailable.'
    }
    if ($SelectedAgent -notin @('Claude', 'Codex')) { throw 'Choose Claude or Codex.' }
    if (-not $WorkingDirectory -or -not (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) { throw 'Choose an existing project folder.' }
    $AdapterPath = Resolve-OrchestratorAdapterPath $AdapterPath
    if (-not [IO.Path]::IsPathRooted($AdapterPath) -or -not (Test-Path -LiteralPath $AdapterPath -PathType Leaf)) {
        throw 'Orchestrator is not configured. Install its local adapter manifest before choosing this role.'
    }
    $manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $AdapterPath | ConvertFrom-Json
    if ($manifest.schema -ne 1) { throw 'Unsupported Orchestrator adapter manifest schema.' }
    foreach ($name in @('python', 'script')) {
        $value = [string]$manifest.$name
        if (-not [IO.Path]::IsPathRooted($value) -or -not (Test-Path -LiteralPath $value -PathType Leaf)) { throw "Adapter $name must name an existing absolute file." }
    }
    if ([IO.Path]::GetExtension($manifest.python) -ne '.exe' -or [IO.Path]::GetExtension($manifest.script) -ne '.py') { throw 'Orchestrator requires a Python executable and Python adapter.' }
    $arguments = @([string]$manifest.script, '--tool', $SelectedAgent.ToLowerInvariant(), '--project', $WorkingDirectory)
    $continuing = $Start -eq 'Continue last'
    if ($continuing) { $arguments += '--continue-last' }
    $linkedContexts = @($Contexts | Where-Object { $_ })
    if ($linkedContexts.Count -gt 8) { throw 'Link no more than eight context folders.' }
    foreach ($context in $linkedContexts) {
        if ($continuing) { continue } # Keep the original workflow source pins.
        if (-not $context -or -not (Test-Path -LiteralPath $context) -or
            ((Test-Path -LiteralPath $context -PathType Leaf) -and [IO.Path]::GetExtension($context) -notin @('.md','.pdf'))) { throw 'Every linked context must be an existing folder, Markdown or PDF file.' }
        if (-not [String]::Equals([IO.Path]::GetFullPath($context).TrimEnd('\'), [IO.Path]::GetFullPath($WorkingDirectory).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
            $arguments += @('--context', [IO.Path]::GetFullPath($context))
        }
    }
    $modelValue = ([string]$Model).Trim()
    if ($modelValue) { $arguments += @('--model', $modelValue) }
    $effortValue = ([string]$Effort).Trim()
    if ($effortValue -and $effortValue -ne 'Default') { $arguments += @('--effort', $effortValue) }
    if ($Prompt) { $arguments += @('--prompt', $Prompt) }
    $arguments += '--launch'
    [pscustomobject]@{
        Executable = [string]$manifest.python
        Arguments = $arguments
        WorkingDirectory = $WorkingDirectory
        SessionRole = 'Orchestrator'
        Agent = $SelectedAgent
        Model = $modelValue
        Effort = $effortValue
        StartMode = $(if ($continuing) { 'Continue last' } else { 'New session' })
        Profile = 'Native CLI role; managed workers and checks; role model follows selection'
    }
}

function Test-OrchestratorReadiness {
    param([Parameter(Mandatory)]$Preview)
    $arguments = @($Preview.Arguments)
    $arguments[-1] = '--describe'
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $Preview.Executable
    $info.Arguments = ($arguments | ForEach-Object { ConvertTo-OrchestratorArgument $_ }) -join ' '
    $info.WorkingDirectory = $Preview.WorkingDirectory
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $info.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    try {
        [void]$process.Start()
        $output = [Launcher.OrchestratorOutput]::Read($process.StandardOutput)
        $errors = [Launcher.OrchestratorOutput]::Read($process.StandardError)
        $deadline = [DateTime]::UtcNow.AddSeconds(20)
        while (-not $process.WaitForExit(50)) {
            if ($output.IsFaulted -or $errors.IsFaulted) { $process.Kill(); throw 'Orchestrator preflight output exceeded its bound.' }
            if ([DateTime]::UtcNow -gt $deadline -or $process.PeakWorkingSet64 -gt 268435456) { $process.Kill(); throw 'Orchestrator preflight exceeded its time or memory bound.' }
        }
        while (-not ($output.IsCompleted -and $errors.IsCompleted)) {
            if ([DateTime]::UtcNow -gt $deadline) { throw 'Orchestrator preflight pipes did not close before the deadline.' }
            Start-Sleep -Milliseconds 25
        }
        if ($output.IsFaulted -or $errors.IsFaulted) { throw 'Orchestrator preflight output exceeded its bound.' }
        if ($process.ExitCode -ne 0) { throw 'Orchestrator could not prepare this project. No terminal was started.' }
        $result = $output.Result | ConvertFrom-Json
        if ($result.allowed -isnot [bool] -or -not $result.allowed) { throw 'Orchestrator is unavailable for this project. No terminal was started.' }
        if ([string]$result.tool -ne $Preview.Agent.ToLowerInvariant() -or
            -not [String]::Equals([IO.Path]::GetFullPath([string]$result.project).TrimEnd('\'), [IO.Path]::GetFullPath($Preview.WorkingDirectory).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Orchestrator preflight returned a different project or agent. No terminal was started.'
        }
        return $result
    } finally { $process.Dispose() }
}

function Start-OrchestratorTerminal {
    param([Parameter(Mandatory)]$Preview)
    $readiness = Test-OrchestratorReadiness $Preview
    $values = @($Preview.Executable) + @($Preview.Arguments)
    $quoted = @($values | ForEach-Object { "'" + $_.Replace("'", "''") + "'" })
    $title = Split-Path -Leaf $Preview.WorkingDirectory
    $quotedTitle = "'" + $title.Replace("'", "''") + "'"
    $quotedWorkspace = "'" + $Preview.WorkingDirectory.Replace("'", "''") + "'"
    $command = '$env:AGENT_LAUNCHER_WORKSPACE = ' + $quotedWorkspace + '; $Host.UI.RawUI.WindowTitle = ' + $quotedTitle + '; & ' + ($quoted -join ' ')
    Start-AgentConsole -Command $command -WorkingDirectory $Preview.WorkingDirectory -Title $title
    return $readiness
}
