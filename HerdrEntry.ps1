# Optional terminal host. Uses a private local adapter, independent of agent role.
function Get-HerdrHostPreview {
    param([Parameter(Mandatory)][string]$WorkingDirectory, [string]$Command = '', [string]$AdapterPath,
          [switch]$SharedSession, [switch]$LaunchShared)
    if (-not $AdapterPath) { $AdapterPath = $env:AGENT_LAUNCHER_HERDR_ADAPTER }
    if (-not $AdapterPath) { $AdapterPath = Join-Path $env:LOCALAPPDATA 'AgentProjectLauncher\herdr-adapter.json' }
    if (-not [IO.Path]::IsPathRooted($AdapterPath) -or -not (Test-Path -LiteralPath $AdapterPath -PathType Leaf)) {
        throw 'Herdr is not configured. Install its local host adapter manifest before selecting Herdr.'
    }
    $manifest = Get-Content -LiteralPath $AdapterPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest.schema -ne 1) { throw 'Unsupported Herdr adapter schema.' }
    foreach ($name in @('python','script')) {
        $value = [string]$manifest.$name
        if (-not [IO.Path]::IsPathRooted($value) -or -not (Test-Path -LiteralPath $value -PathType Leaf)) {
            throw "Herdr adapter $name must name an existing absolute file."
        }
    }
    if ([IO.Path]::GetExtension($manifest.python) -ne '.exe' -or [IO.Path]::GetExtension($manifest.script) -ne '.py') {
        throw 'Herdr requires a Python executable and Python host adapter.'
    }
    $arguments = @([string]$manifest.script,'--project',$WorkingDirectory)
    if ($SharedSession) { $arguments += '--shared' }
    if ($Command) {
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Command))
        if ($encoded.Length -gt 20000) { throw 'The Herdr command is too long for Windows transport. Shorten the opening prompt.' }
        $arguments += @('--encoded-command',$encoded)
    }
    if ($SharedSession -and $LaunchShared) { $arguments += '--launch-shared' }
    elseif (-not $SharedSession) { $arguments += '--launch' }
    [pscustomobject]@{ Executable=[string]$manifest.python; Arguments=$arguments; WorkingDirectory=$WorkingDirectory; TerminalHost=$(if ($SharedSession) {'Herdr'} else {'Herdr isolated'}); SharedSession=[bool]$SharedSession }
}

function Test-HerdrHostReadiness {
    param([Parameter(Mandatory)]$Preview)
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $Preview.Executable
    $describeArgs = @($Preview.Arguments[0],'--project',$Preview.WorkingDirectory)
    if ($Preview.SharedSession) { $describeArgs += '--shared' }
    $describeArgs += '--describe'
    $info.Arguments = ($describeArgs | ForEach-Object { ConvertTo-OrchestratorArgument $_ }) -join ' '
    $info.WorkingDirectory = $Preview.WorkingDirectory
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $info.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    try {
        [void]$process.Start()
        $output = [Launcher.OrchestratorOutput]::Read($process.StandardOutput)
        $errors = [Launcher.OrchestratorOutput]::Read($process.StandardError)
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        while (-not ($process.HasExited -and $output.IsCompleted -and $errors.IsCompleted)) {
            if ($output.IsFaulted -or $errors.IsFaulted -or [DateTime]::UtcNow -gt $deadline) {
                if (-not $process.HasExited) { $process.Kill() }
                throw 'Herdr preflight exceeded its protocol bound. No terminal started.'
            }
            Start-Sleep -Milliseconds 50
        }
        if ($process.ExitCode -ne 0) { throw 'Herdr runtime is unavailable. No terminal started.' }
        $result = $output.Result | ConvertFrom-Json
        if ($result.allowed -isnot [bool] -or -not $result.allowed -or $result.terminal_host -ne 'Herdr' -or
            -not [String]::Equals([IO.Path]::GetFullPath([string]$result.project),[IO.Path]::GetFullPath($Preview.WorkingDirectory),[StringComparison]::OrdinalIgnoreCase)) {
            throw 'Herdr preflight did not confirm this project. No terminal started.'
        }
        return $result
    } finally { $process.Dispose() }
}

function Start-HerdrWorkspace {
    param([Parameter(Mandatory)][string]$WorkingDirectory, [Parameter(Mandatory)][string]$Command,
          [string]$AdapterPath)
    $preview = Get-HerdrHostPreview -WorkingDirectory $WorkingDirectory -AdapterPath $AdapterPath -SharedSession
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Command))
    if ($encoded.Length -gt 20000) { throw 'The Herdr command is too long for Windows transport. Shorten the opening prompt.' }
    $values = @($preview.Arguments[0],'--project',$WorkingDirectory,'--shared','--create-workspace','--encoded-command',$encoded)
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $preview.Executable
    $info.Arguments = ($values | ForEach-Object { ConvertTo-OrchestratorArgument $_ }) -join ' '
    $info.WorkingDirectory = $WorkingDirectory
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $info.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    try {
        [void]$process.Start()
        $output = [Launcher.OrchestratorOutput]::Read($process.StandardOutput)
        $errors = [Launcher.OrchestratorOutput]::Read($process.StandardError)
        $deadline = [DateTime]::UtcNow.AddSeconds(35)
        while (-not $process.WaitForExit(50)) {
            if ($output.IsFaulted -or $errors.IsFaulted -or [DateTime]::UtcNow -gt $deadline) {
                $process.Kill()
                throw 'Herdr did not confirm the workspace launch. Check the Herdr sidebar before trying again.'
            }
        }
        while (-not ($output.IsCompleted -and $errors.IsCompleted)) {
            if ([DateTime]::UtcNow -gt $deadline) { throw 'Herdr launch output did not close. Check the Herdr sidebar before trying again.' }
            Start-Sleep -Milliseconds 25
        }
        $result = $null
        if ($output.Result.Trim()) {
            try { $result = $output.Result | ConvertFrom-Json } catch { }
        }
        if ($process.ExitCode -ne 0) {
            if ($result -and $result.workspace_created -and $result.workspace_id) {
                throw ("Herdr created workspace {0}, but agent startup is uncertain. Inspect that space before retrying; no command was replayed." -f $result.workspace_id)
            }
            throw 'Could not add a workspace to the existing Herdr session. Open Herdr and check its sidebar before retrying.'
        }
        if ($result -and $result.PSObject.Properties['needs_client'] -and $result.needs_client) { return $result }
        if ($result.allowed -isnot [bool] -or -not $result.allowed -or -not $result.workspace_id -or -not $result.pane_id) {
            throw 'Herdr did not confirm the new workspace and pane. Check the Herdr sidebar before trying again.'
        }
        return $result
    } finally { $process.Dispose() }
}

function Get-HerdrConsoleCommand {
    param([Parameter(Mandatory)]$Preview)
    $values = @($Preview.Executable) + @($Preview.Arguments)
    return '& ' + (($values | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ' ')
}
