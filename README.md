# Agent Project Launcher

A small Windows launcher for starting and monitoring Claude Code and OpenAI Codex sessions across your projects.

## Features

- Start Claude Code or Codex in any folder on the machine, including a network share.
- Choose model, permission level, network policy, opening prompt and extra writable folders.
- Resume or pick an earlier session.
- View live terminal sessions, active model, context health, limits when available, and permissions.
- Click a live session to jump to its terminal tab with the caret in its prompt, or to compact it.
- Compact every live session in one action.
- Remember settings per project.
- Optionally link a project to a notes folder through `AGENTS.md`.

## Requirements

- Windows 10 or Windows 11.
- Windows PowerShell 5.1 or newer.
- [Claude Code](https://code.claude.com/docs) and/or [OpenAI Codex CLI](https://learn.chatgpt.com/docs/codex/cli) installed and signed in.
- Windows Terminal is recommended.

The launcher discovers `claude` and `codex` from `PATH`. Custom executable paths can be entered in `config.json`, which is read from the launcher's own folder when a copy sits there and otherwise from `%LOCALAPPDATA%\AgentProjectLauncher`. `settings.json` follows the same rule, so a checkout run where it sits keeps code and configuration in one place. The recognised keys are `ProjectRoot`, `NotesRoot`, `NotesProjectsRoot`, `ClaudePath`, `CodexPath` and `ClaudeAccountLimits`.

## Install

1. Download and extract `AgentProjectLauncher-Windows.zip`.
2. Right-click `Install.ps1` and choose **Run with PowerShell**.
3. Open **Agent Project Launcher** from the Start menu or desktop.

If Windows blocks the script, open PowerShell in the extracted folder and run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
```

The configured roots are `Documents\Projects` and `Documents\Notes`. The notes root is named in the folder list after the folder it points at, so a root at `D:\Vault` is listed as `Vault`. A vault that keeps its projects in a subfolder can name it as `NotesProjectsRoot`: the folder list and the pickers open on that subfolder, while paths are still shown relative to the root above it. They are a shorthand for
the folder list and the picker, not a restriction: any folder on the machine can be a work
folder, including a UNC share such as `\\server\share`. To choose different roots:

```powershell
.\Install.ps1 -ProjectRoot 'D:\Code' -NotesRoot 'D:\Notes'
```

The installer writes application files to `%LOCALAPPDATA%\Programs\AgentProjectLauncher` and user configuration to `%LOCALAPPDATA%\AgentProjectLauncher`. It does not install Claude Code or Codex.

## Privacy and network behavior

The launcher runs locally and does not collect analytics. It reads local process metadata and local Claude/Codex session transcripts to build the Live sessions overview; it does not read or display message content.

Going to a session, or compacting one, brings its terminal tab to the front. Compacting then types
`/compact` into that window as keystrokes, because a terminal CLI offers no other way in. The tab is
located in a short-lived helper process, and a session whose tab cannot be identified with certainty
is skipped rather than guessed at. Anything already typed but unsent in a session is sent along with
the command, and moving the mouse or keyboard during a send can carry the keystrokes elsewhere.

Claude account-limit fetching is off unless `ClaudeAccountLimits` is set to `true` in `config.json`. It is off by default because the check reads the local Claude credential file and calls an endpoint Anthropic does not document or support, which can change or stop working without notice. Claude transcript context usage is still shown when available. Codex limits are read from local session metadata when available.

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
