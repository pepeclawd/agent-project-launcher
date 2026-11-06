# Herdr terminal host

Choose **Terminal** or **Herdr** beside the Session role.
Ordinary/Orchestrator remains an independent choice, for either Claude or Codex.
Terminal is the default. Reopen the launcher after updating its files to see the
new control.

**Herdr** uses one stable launcher-owned session. The first launch opens a
Herdr tab and starts the selected agent in the chosen project. Later launches
create and focus additional project workspaces in that session; they appear in
the same Spaces sidebar without opening another tab. If the session is stopped,
the next launch bootstraps it again. On an uncertain launch result, inspect the
Herdr sidebar before retrying.

If the Herdr client tab is closed, the next launcher start reopens that shared
session. Closing the launcher itself does not stop Herdr. Older saved isolated
host preferences migrate to Herdr; existing sessions are left running.

The launcher-owned session config keeps the outer terminal title `Herdr` while
project names stay in the Spaces sidebar. The previously absent user-level
Herdr config was also given this title preference; the launcher does not
rewrite that global config. Herdr panes are not integrated into the launcher's
Windows Terminal focus/handoff automation; use Herdr itself to switch panes and
manage their life.

For Orchestrator, linked project context folders follow the session on either
terminal host and remain read-only. Orchestrator uses the current automatic
workflow adapter, not the exhausted historical pilots.

The optional local manifest is
`%LOCALAPPDATA%/AgentProjectLauncher/herdr-adapter.json`, with schema 1 and absolute
`python` executable and `script` path to the host adapter. `-HerdrAdapter` or
`AGENT_LAUNCHER_HERDR_ADAPTER` can override that location. The pinned runtime is
validated by the adapter; no global Herdr installation or PATH edit is performed.
The package contains the helper, not machine-specific paths or the Herdr binary.
Herdr uses private configuration and reuses one stable launcher-owned session
across projects without changing the global Herdr configuration.

CLI mode uses `-TerminalHost Herdr` for the shared launcher session. `-DryRun` validates the
host without starting agents or models. Missing configuration is an error,
with no fallback to another terminal host.
Long commands exceeding the native Windows transport bound are rejected before
launch. User commands/prompts are not written to launcher payload files. The
launcher uses private configuration, disables pane history, and preserves its
own shared session state between projects.

The runtime remains pinned at the locally tested version; upgrading it is a
separate compatibility task. No public release or push is implied by this local
integration. See the controller's current verification report for test evidence
and the distinction between transport verification and model-task acceptance.
