# Changelog

## Unreleased

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
