# Changelog

## Unreleased

- Handoff, status dialog: it now says what the status is for (the briefing the receiving agent starts
  from, since it does not see the old conversation: goal, done, in progress, next steps) and why it
  appeared, for example that the source session could not be asked to write it. The text box no
  longer opens with every heading selected, so typing does not wipe them.
- Handoff and **Compact** work for sessions in Herdr. With **Session writes it** the launcher types
  the handoff request into the source's Herdr pane (`pane send-text`, then Enter) and the session
  writes its own status, so nothing has to be written by hand. **Compact** and **Compact all** type
  `/compact` the same way. A Herdr pane has no window to bring forward, so it is typed into where
  it is; anything already typed but unsent in it is sent along. Writing the status by hand is now
  only the fallback when the session cannot be reached or does not finish within 45 seconds.
- Handoff layout: **Cancel handoff** was drawn under a second, ordinary **Cancel** button, which
  closes the whole launcher. Only the handoff Cancel is shown now. **Browse** and **Remove** are
  readable (dimmed) while the folder is fixed, and **Terminal** can be chosen, so the receiving
  session can open in Herdr. **Role** stays Ordinary, with a hint saying why. Status, When? and Note
  line up with their labels again.

- Fixed every Herdr lookup failing silently in a launcher started from the desktop shortcut, which is
  why Herdr tab names never reached Live sessions and Go to this session did not work for Herdr.
  The launcher's Herdr server runs in a private environment (`XDG_CONFIG_HOME`, `XDG_STATE_HOME`,
  `HERDR_*`) that holds its socket. A launcher started from a terminal inside Herdr inherited it, one
  started from the shortcut did not, so the Herdr CLI looked in the default folder and found nothing.
  The launcher now reads that environment from the Herdr server process and uses it for its calls.

- Fixed Herdr tab names never reaching Live sessions in a launcher that had been open for a while.
  The launcher remembered which tab each process sat in and kept using it after tabs were moved,
  renamed or closed, so the name was looked up in a tab that no longer existed. It now takes a fresh
  picture of Herdr on every refresh (at most every four seconds) and also finds a pane through its
  shell, so an agent that is running a tool is still found.

- A session in Herdr is titled with its tab name exactly as Herdr shows it, including a bare tab
  number or "Terminal". The launcher no longer substitutes a title of its own for those. A title
  you gave in New session or with **Set session title** still wins. Refresh re-reads the tab names.

- New session has an optional **Title** field. A title typed there is the session's name in Live
  sessions and, for sessions in Herdr, the name of its Herdr tab. Left empty, the launcher names
  the session after what it is working on as before. The title is kept under the session's marker
  in `session-titles.json`, so it survives a launcher restart. A title set later with **Set session
  title** is put on the Herdr tab the next time Live sessions refreshes. The launcher names a tab
  once; if you rename it in Herdr afterwards, it is not renamed back. Role, Terminal and Start got
  narrower to make room, and the field is not shown for Orchestrator or handoff.

- **Go to this session** on a session in a private Herdr server (one the launcher has no session
  name for, such as an Orchestrator pilot) now says so instead of "tab not found".

- Live sessions: a Codex session started with `codex resume` (for example `resume --last`) is now
  matched to the transcript it resumed, so it shows its real model, effort, context and title
  instead of "New session" and "waiting". A resumed session keeps writing to the rollout it was
  created in, which can be days old, and the launcher only looked in today's folder.
- Live sessions: an Orchestrator session is listed again. The workflow controller starts it
  through Python processes, which the launcher did not follow up to the terminal, so it was
  skipped. Its transcript is read from the folder it runs in rather than the project's. Old
  controller sessions left in private pilot Herdr servers are still left out, and a Herdr tab
  named just "Terminal" no longer becomes the session title.

- Live sessions: **Compact all** and **Refresh** sit against the right edge, and the session
  table starts 12 px lower so the Claude and Codex limit lines have room above the column headers.
  The window opens 12 px taller to fit.
- New session layout fills the whole width. Browse, Remove and Link sit against the right edge and
  the work-folder field and the lines under it run out to them; Agent, Model, Effort and
  Permissions share the full width; Role and Terminal moved down into the Session row beside Start
  and First message (Status, When? and Note in handoff mode); and Open terminal / Cancel sit at the
  panel's right edge. The "Also in scope" row under Advanced options follows the same pattern.
- **Go to this session** works for sessions in Herdr. They share one Windows Terminal tab, so the
  launcher asks Herdr to focus the session's pane (`agent focus`) and then brings the Herdr
  window to the front. Codex panes are found too: Herdr reports the `cmd.exe` shim above
  `node` and `codex.exe`, so every process from the agent up to its terminal is matched. Only the
  launcher's own Herdr session (`orch-launcher-spaces`) is reachable; sessions under other Herdr
  servers still say the tab was not found. **Compact** still types into a Windows Terminal tab and
  does not reach Herdr panes.
- Account limits are shown once, at the top of Live sessions, instead of in a Limits column on
  every row: **Claude** in orange and **Codex** in blue, one above the other with the numbers
  aligned, in place of the description line. The number is green below 60%, amber from 60% and
  red from 80%, by the higher of the 5-hour and 7-day windows. Hover either for the reset times.
  An agent with no live session is left out.
- A session in Herdr takes its title from the tab name you gave it in Herdr (for example
  "til afklaring") instead of one the launcher derives. Untitled Herdr tabs and a title set with
  **Set session title** are unchanged: the launcher's own title still wins. The launcher finds the
  tab through Herdr's read-only CLI (`tab list`, `agent list`, `pane process-info`).
- Live sessions now lists a `claude` or `codex` started by hand in a Herdr pane. It runs under the
  pane's own shell with no PowerShell in between, which the launcher used to skip. Claude sessions
  without a launcher marker are placed through Claude's own `~/.claude/sessions/<pid>.json`
  registry (session id and working folder), so their project, transcript, title, effort and
  context are exact instead of guessed from timestamps.
- Starting a session in a folder that already has one no longer asks for confirmation. Only
  **Continue last** on a session that is still open is refused, because it cannot work.
- Sessions that the launcher started inside Herdr now show their real project instead of
  "(external)". Herdr passes the shell's setup as a base64 `-EncodedCommand`; the launcher now
  decodes it to read the workspace. The row tooltip says whether a session runs in Herdr or
  Windows Terminal. Prompt-based titles also skip text that starts with a quote mark (pasted
  replies) and attachment markers like "[Image #2]".
- Live sessions are titled by what they are working on instead of "Session HH:mm". A title you set
  with **Set session title** still wins. Otherwise Codex uses its own thread name, and Claude uses
  `/rename` (or an external `--name`), then its own summary, then the latest real prompt boiled
  down to one line. Hover a row to see where its title came from. "New session HH:mm" only
  shows before the first prompt has been sent.
- Live sessions now read model, effort and context for every session. Codex terminal sessions
  started on older builds (rollout tagged `source=vscode` instead of `cli`) were never matched to
  their transcript and showed "default / waiting". Claude sessions started outside the launcher
  with `--name` are now found by that name across all project folders instead of being skipped.
- Simplified terminal selection to Terminal or Herdr. Herdr always adds projects to the same shared session; older saved isolated preferences migrate to Herdr.
- Fixed adding a second project to the shared Herdr session: the workspace helper is now imported into the launcher scope even after Herdr preflight has loaded its other helpers. The persistent outer Windows Terminal tab is titled **Herdr**; project names remain in Herdr's Spaces sidebar.
- Successful Herdr workspace replies may omit `needs_client`; both PowerShell callers now handle that optional field under strict mode. A regression exercises the real console and workspace helpers and checks that no second terminal opens.

- Herdr now keeps one persistent launcher session and opens later projects as focused workspaces in its Spaces sidebar, without another terminal tab. `Herdr isolated` retains the previous per-launch private-session behavior; Terminal remains the default.

- The desktop and Start menu shortcuts now start the launcher in a detached hidden PowerShell process, so closing a terminal window does not close the launcher.
- The launcher now has its own Windows taskbar identity, keeping its taskbar button with the launcher icon instead of grouping it under PowerShell.
- Live session agent names use orange for Claude and blue for Codex.
- Live sessions show each editable, locally saved title after its project name in one sortable Project column. Drag the handles between columns to adjust their spacing; widths are saved and reflow with the window.
- New session content stays a fixed, readable width and remains centered as the launcher window grows; its action buttons stay centered below it.
- The launcher window is wider by default and can be resized horizontally to make more room for session titles.
- The launcher starts again when a saved project or attached folder is on a network share whose
  host is offline. Such folders are skipped instead of stopping startup with "The network path
  was not found", and a quick check of the share's host avoids the long Windows timeout per path.
- The Live sessions view has an Effort column. It shows each session's current reasoning effort
  from its transcript, so `/effort` changes are picked up, and falls back to the launch flag.
- Claude context lookup now finds transcripts for UNC workspaces whose share or project names
  contain underscores and spaces.
- A remembered Codex model that is no longer in the CLI's model cache now falls back to the
  current Codex default instead of failing every newly launched session.
- The Live sessions view now follows Claude into the new transcript created by `/clear`, so its model and
  context do not remain stuck on the session state from before the clear.
- Terminal tabs now keep a unique launcher title instead of allowing agent-generated titles to
  replace it. Handoffs can therefore target the correct tab when several sessions use one folder,
  and checkpoint failures now report the specific tab-matching reason.
- The first-message box is cleared after a terminal opens successfully, so the next new session
  starts with an empty message instead of reusing the previous session's opening prompt.
- Live sessions no longer hide Codex sessions launched with `Ask me`, `Accept edits`, or another
  mode that passes the `--sandbox` permission flag.
- Session handoff: a live session can be handed off to Claude or Codex. The launcher writes a
  structured handoff file under `.agent\handoffs` in the work folder, with a short status written
  either by the old session or by hand, and opens the receiving agent on that file. The old
  conversation is not passed on. The new `-HandoffFile` parameter starts an agent on an existing
  handoff file from the command line.
- A handoff can be planned while the source works: request a checkpoint at its next safe point or
  automatically when a fresh account-limit measurement reaches 85%. The launcher waits for a
  complete status before opening the recipient and offers cancellation and manual completion.
- Handoff timing is now selected on the preparation screen before clicking **Plan / hand off**.

## 1.0.5

- Starting a session leaves the launcher open, making it possible to launch or
  inspect another session without reopening the app.
- Live sessions say `waiting` before an agent has completed its first turn and
  written a context measurement, with the reason available on hover.
- The launcher window comes to the front. Started from a shortcut that hides the
  console, it was created but never raised, so it opened behind whatever was already
  on screen and looked like it had not opened at all.
- Sessions open in a Windows Terminal window of their own rather than as a tab in
  whichever window was used most recently, where they were easy to miss entirely.
- A launch that fails now says so. It ran after the window had closed, so the error
  went to a hidden console and the launcher simply vanished.
- `config.json` and `settings.json` are read from beside the script when a copy sits
  there, and from `%LOCALAPPDATA%\AgentProjectLauncher` otherwise.
- New `NotesProjectsRoot` key for a vault that keeps its projects in a subfolder: the
  folder list and pickers open there, while paths stay relative to the root above it.
- The notes root is named after the folder it points at, so a root at `D:\Vault` is
  listed and can be typed as `Vault` rather than `Notes`.
- Vault links are recognised under any label, not only `Vault notes:`, and a path that
  begins at the vault folder's own name resolves as well as an absolute one.
- Fixed: reading a vault link threw, because a .NET call had its argument split on the
  comma inside its parentheses.
- New `ClaudeAccountLimits` key, off by default, enabling the Claude account-limit
  column. It reads the local Claude credential file and calls an endpoint Anthropic
  does not document, so it stays opt-in.
- `Install.ps1` keeps config keys it was not asked about instead of resetting them.

## 1.0.4

- The work folder can be any folder on the machine. The configured roots are a shorthand for the
  list and the picker, not a boundary.
- UNC shares work throughout: paths resolve to `\\server\share\...` rather than the provider-qualified
  form, and a share root is named after its host and share instead of being handed an empty name.
- The folder picker labels its path box, offers any share already in use as a browsable root, and
  adds a share to the tree as soon as one is typed.
- Two folders with the same name are told apart in the folder list by the folder above them.
- Live sessions: clicking a session offers going to its terminal tab, with the caret in its prompt
  and nothing typed, or compacting that one session.
- Live sessions: a Compact all button types `/compact` into every session in turn, skipping any
  whose tab cannot be identified with certainty rather than guessing.
- The tab lookup runs in a helper process. Done in-process, the first UI Automation call made the
  launcher DPI-aware and its window collapsed to a fraction of its size on a scaled display, with
  the text still drawn full size and every column and button cutting off its own text.
- Only tabs belonging to a terminal host are eligible, so a browser or Explorer tab that happens to
  share a session's name can no longer be typed into.
- Fixed tab selection never working at all: candidates accumulated into `$matches`, which every
  regex test in the loop overwrote.

## 1.0.3

- Opening Advanced options no longer pushes Open terminal and Cancel out of the window.
- Folding Advanced options away returns the window to its previous height.
- The minimum window height follows the layout, so the buttons can no longer be dragged behind the panel.
- The Claude model list is the four aliases only; a version-pinned id in the CLI config folds onto its alias.
- Live sessions: dropped the Health column and moved the reading onto the colour of the Context value.
- Live sessions: fixed Claude context going unread on long turns, and stopped counting subagent turns as the session's own.
- Live sessions: a session is matched only to a transcript created at or after it started, and an uncertain match is no longer cached.
- Live sessions: Codex rollouts are matched by the timestamp in the filename, which recent builds no longer reflect in the file's creation time.

## 1.0.2

- Restricted window resizing to height only; width stays fixed.
- Removed maximize behavior that could widen the layout.
- Fixed stale custom-border artifacts while resizing vertically.
- Reduced first-frame white flashes with buffered rendering and hidden pre-paint.

## 1.0.1

- Made the launcher window resizable and maximizable.
- Added a minimum window size that keeps the Live sessions table readable.
- Live sessions now use additional width and height when the window grows.
- Removed the unnecessary horizontal scrollbar while retaining vertical scrolling.

## 1.0.0

- Initial public release.
- Claude Code and OpenAI Codex launch controls.
- Project-specific models, permissions, network choices and extra scope.
- Live session overview with context health and locally available limits.
- Configurable project and notes roots.
- Windows installer, shortcuts and uninstaller.
