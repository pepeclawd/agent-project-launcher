# Changelog

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
