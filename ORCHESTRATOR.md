# Optional Orchestrator sessions

Start: New session creates a new managed workflow. Start: Continue last reloads the latest registered workflow for the selected original project, preserving its isolated candidate, source pins, attempt history and estimate allowance. Close its old conversation before continuing; an occupied/unavailable workflow fails safely and never silently creates a replacement. Reopen the launcher to load this behavior. Pick a session is not supported for managed workflows.

Future model metadata maps every code/review attempt and repair round to its job and requested CLI model. Main-agent launcher selections are recorded separately. These are requested model identities, not independently provider-confirmed identities.

The Session row offers Ordinary and Orchestrator. Ordinary remains the default.
The independent terminal host selector offers Terminal and Herdr; see [HERDR.md](HERDR.md).
Orchestrator opens the selected Claude or Codex CLI as a managed project role.
Select a project, agent, model and effort, optionally enter a goal, then open
the terminal. With no opening goal, the terminal waits for your first message.
The role receives the selected project's linked context folders as read-only
Markdown through the controller, in both Terminal and Herdr sessions.

The private controller prepares the isolated workspace, manages delegated jobs,
runs supported checks and handles bounded repairs. Its worker allowance is
separate from the native role conversation's own CLI/account usage. Main merge,
remote publication, deployment and economic writes require their own approval.

The launcher does not implement the worker controller. A local adapter manifest
must be configured at `%LOCALAPPDATA%\AgentProjectLauncher\orchestrator-adapter.json`:

```json
{"schema":1,"python":"C:/absolute/path/to/python.exe","script":"C:/absolute/path/to/workflow_entry.py"}
```

An explicit `-OrchestratorAdapter` or `AGENT_LAUNCHER_ORCHESTRATOR_ADAPTER`
environment variable takes precedence. No machine-specific adapter path is
committed in this public launcher. Missing/unavailable configuration refuses the
Orchestrator launch, without silently opening an Ordinary session.

Command-line and DryRun mode accept `-SessionRole Orchestrator`. The adapter
receives `--tool`, `--project`, optional `--model`, `--effort`, `--prompt`, and
`--describe` or `--launch`. Describe is read-only and starts no models or jobs.
Extra folders, permission overrides, resume, handoff, personas and web overrides
are unavailable in this role. Ordinary controls retain their saved values when
you switch back; the role itself is selected for each new session.

This local integration has not been published or pushed. The controller's own
documentation records which worker/check flows have actually been verified.
# Checking the selected session

The launcher remembers Session and Terminal choices after reopening. Its launch
button says `[ Orchestrator ]` for managed delegation and `[ Ordinary ]` for a
normal agent. Reopen a launcher already running when its source was updated.
An existing agent session keeps its original configuration.

Orchestrator startup verifies its MCP connection before opening Claude/Codex and
prints the number of linked Markdown notes. Its terminal tab uses the project
name. Codex's native `/status` shows CLI settings, not linked context.
Ask the Orchestrator conversation to list available linked notes; it uses the
controller status tool's `context_files` list. Only the linked folders are
available through that tool. Existing Markdown files/folders in the green Vault
link are included as well as explicitly attached folders; single-file links do
not expose neighbouring notes.

# Keeping notes current

New Orchestrator sessions support current-note reads and exact fragment updates
through their controller status tool. Existing project task/status/documentation
notes and selected vault notes can be maintained while planning and after verified
work. Note writes go to canonical original files with revision checks and backups;
code changes remain on the isolated branch. The controller records factual job
outcomes automatically; the conversational role reconciles relevant checkboxes
and decisions. Personal memory/instruction files and whole-note replacement stay
outside this editing scope. A competing edit requires reading and reconciling the
new revision. Reopen an existing session to load the updated schema/instructions.

