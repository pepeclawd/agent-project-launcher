# Agent Project Launcher

A small Windows launcher for starting and monitoring Claude Code and OpenAI Codex sessions across your projects.

## Features

- Start Claude Code or Codex in any project folder.
- Choose model, permission level, network policy, opening prompt and extra writable folders.
- Resume or pick an earlier session.
- View live terminal sessions, active model, context health, limits when available, and permissions.
- Remember settings per project.
- Optionally link a project to a notes folder through `AGENTS.md`.

## Requirements

- Windows 10 or Windows 11.
- Windows PowerShell 5.1 or newer.
- [Claude Code](https://code.claude.com/docs) and/or [OpenAI Codex CLI](https://learn.chatgpt.com/docs/codex/cli) installed and signed in.
- Windows Terminal is recommended.

The launcher discovers `claude` and `codex` from `PATH`. Custom executable paths can be entered in `%LOCALAPPDATA%\AgentProjectLauncher\config.json` after installation.

## Install

1. Download and extract `AgentProjectLauncher-Windows.zip`.
2. Right-click `Install.ps1` and choose **Run with PowerShell**.
3. Open **Agent Project Launcher** from the Start menu or desktop.

If Windows blocks the script, open PowerShell in the extracted folder and run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
```

The default folders are `Documents\Projects` and `Documents\Notes`. To choose others:

```powershell
.\Install.ps1 -ProjectRoot 'D:\Code' -NotesRoot 'D:\Notes'
```

The installer writes application files to `%LOCALAPPDATA%\Programs\AgentProjectLauncher` and user configuration to `%LOCALAPPDATA%\AgentProjectLauncher`. It does not install Claude Code or Codex.

## Privacy and network behavior

The launcher runs locally and does not collect analytics. It reads local process metadata and local Claude/Codex session transcripts to build the Live sessions overview; it does not read or display message content.

Claude account-limit fetching is intentionally disabled in this public build because Claude does not provide a supported public endpoint for it. Claude transcript context usage is still shown when available. Codex limits are read from local session metadata when available.

Permission and network controls are passed to the selected CLI. Review the hover help before using broad permissions. `Full access` deliberately removes Codex sandbox protections.

## Uninstall

Run:

```powershell
& "$env:LOCALAPPDATA\Programs\AgentProjectLauncher\Uninstall.ps1"
```

Use `-KeepSettings` to retain configuration and remembered project settings.

## Configuration

Configuration lives at `%LOCALAPPDATA%\AgentProjectLauncher\config.json`:

```json
{
  "ProjectRoot": "C:\\Users\\you\\Documents\\Projects",
  "NotesRoot": "C:\\Users\\you\\Documents\\Notes",
  "ClaudePath": "",
  "CodexPath": ""
}
```

Empty CLI paths mean automatic discovery from `PATH`.

## License

MIT. See [LICENSE](LICENSE).
