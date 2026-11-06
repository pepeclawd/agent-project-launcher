# Agent Project Launcher

A small Windows launcher for starting and monitoring Claude Code and OpenAI Codex sessions across your projects.

## Features

- Choose Terminal or the shared [Herdr host](HERDR.md), independently of Ordinary/Orchestrator role. Herdr opens projects as Spaces in the same persistent tab and requires a configured local adapter; no binary is bundled.

- Start Claude Code or Codex in any folder on the machine, including a network share.
- Choose model, permission level, network policy, opening prompt and extra writable folders.
- Resume or pick an earlier session.
- View live terminal sessions, active model, context health, limits when available, and permissions. Each session shows its project folder followed by its editable title in one **Project** column. Click the header to sort by project, or drag the handles between columns to resize them; widths are saved between launches.
- Click a live session to jump to its terminal tab with the caret in its prompt, or to compact it.
- Compact every live session in one action.
- Hand a live session over to Claude or Codex through a short handoff file.
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

## Session handoff

A handoff moves work from one live session to a fresh one, in either direction: Claude to Codex,
Codex to Claude, or the same agent on another model. The receiving agent reads a short handoff file,
not the old conversation.

1. In **Live sessions**, click a session and choose **Hand off this session...**.
2. The **New session** view switches to handoff mode for that session's work folder. The receiving
   agent, model, effort and permissions are set with the ordinary pickers. The agent defaults to the
   other one.
3. Under **Status**, choose who writes the summary:
   - **Session writes it**: the launcher types a one-line request into the old session. That session
     writes its status to `.agent\handoffs\<id>.status.md` under fixed headings (Goal, Done, In
     progress, Next steps, Open questions and risks, Key files), and the launcher waits for the file.
   - **I write it**: a dialog with the same headings, filled in by hand.

   The handoff falls back to writing it by hand if the old session is read-only, has closed or has a
   tab that cannot be identified. The same fallback is offered while waiting.
4. Choose **When?** on the handoff screen, then click **Plan / hand off**. **Cancel handoff** sits beside that button below the settings and returns to **Live sessions** without closing the launcher:
   - **Hand off now** requests a status immediately, waits briefly and offers manual status if needed.
   - **Checkpoint at next safe point** asks the source to finish its current safe step, write a
     checkpoint and stop. The launcher starts the recipient when the status is complete.
   - **Automatic at 85% account use** arms the handoff now and sends that checkpoint request when a
     fresh account-limit measurement reaches 85%. The launcher checks every 15 seconds. This is the
     account limit shown under **Limits**, not the context-window percentage. If no fresh limit
     measurement is available, it waits; it does not guess from context size.

While armed, the source row shows `[planned]` in **Live sessions**. Its menu offers **Cancel planned
handoff** and **Complete planned handoff manually...**. Cancellation stops monitoring; it cannot
recall a checkpoint request already sent. The launcher must remain open for the automatic watcher
to run. A recipient is started only after the status file has stopped changing and contains the
required headings. If the source closes without a status or its terminal cannot be reached, the
launcher offers a manual status instead of starting a recipient on an empty handoff.

The work folder stays fixed to the source session during handoff. A scheduled handoff needs
**Session writes it** and a writable source session. A source in **Ask me** mode may ask you to
approve writing its checkpoint. Choosing the same agent for an account-limit trigger may put the
receiving session under the same account limit. The launcher sends a normal message into the
source terminal; it cannot guarantee a checkpoint if the CLI hits its limit before processing that
message. [Claude Code documents how messages queued during tool calls are delivered](https://code.claude.com/docs/en/interactive-mode#queue-messages-while-claude-works).

The handoff file is Markdown with a front matter block: id, time, work folder, the source and
receiving agent, model and permissions, and where the status came from (`agent`, `manual` or
`none`). Below that come instructions for the receiving agent, the status, an optional note from
you, and a snapshot the launcher takes itself: branch, `git status --short` and recent commits.
The instructions tell the receiving agent to check the status against the repository before relying
on it.

The old session is left running, so you can close it once the new one has taken over. Handoff files
stay in the project. Add `.agent/` to the project's `.gitignore` if they should not be committed.

An existing handoff file can also be passed on the command line:

```powershell
.\AgentProjectLauncher.ps1 -Agent Codex -Project 'D:\Code\MyApp' -HandoffFile '.agent\handoffs\20260915-143210-claude-to-codex.md'
```

The non-UI threshold, status and single-recipient scenario can be checked with
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\PlannedHandoff.ps1`.

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
