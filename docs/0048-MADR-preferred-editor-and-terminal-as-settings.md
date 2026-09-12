---
status: "accepted"
date: 2026-09-12
decision-makers: [Maintainer]
consulted: []
informed: [Magic Git contributors]
verified: 2026-09-12
---

# Preferred editor and preferred terminal are settings, stored by bundle identifier — and the system default stays the default

## Context and Problem Statement

"Open file" opened nothing on the maintainer's Mac. `FileActions.openFiles` ran
`open -a 'Visual Studio Code'`, VS Code is not installed there, `open` exited non-zero, and every
caller discarded the result — no window, no error, no log line. `11f9ed7` fixed that by opening each
path with the user's own default application for its type, falling back to the default text editor,
and reporting a failure instead of dropping it.

That fix removes the hardcode for *files*. It leaves two questions this record answers: should the
app let the user **choose** an editor rather than always following the per-type default, and what is
to be done about "Open in Terminal", which is still hardcoded and cannot be fixed the same way.

### F1 — Where the hardcode came from, and what replaced it

`5e93607` (merged as PR #4, *fix-open-files-in-vscode*) replaced `Process.run('open', absolutePaths)`
with the pinned `-a 'Visual Studio Code'`. `11f9ed7` restored the default-application behaviour,
added an `open -t` fallback for types with no registered handler, made failure throw
`FileOpenException`, and routed the four menu call sites through `runAction` so a failure is shown.
`test/file_actions_test.dart` guards it, and was seen to fail with the pin reintroduced.

### F2 — Files and terminals are not symmetrical

Launch Services holds a default handler **per content type**, which is exactly what plain
`open <path>` consults — so for files, "use the user's choice" needs no setting at all; it is the
default behaviour. There is **no equivalent for terminals**: macOS has no default-terminal role, so
`open -a 'Terminal'` in `lib/features/worktrees/worktrees_view.dart:484` has nothing to defer to. A
user of iTerm2, Warp, Ghostty, kitty or WezTerm gets Terminal.app and has no way to say otherwise.

The asymmetry is the whole design question: for files a setting is an **override** of a default that
already works; for terminals a setting is the **only** way the user's choice can be expressed.

### F3 — The terminal call has the same discarded-status bug

`_openInTerminal` catches exceptions but never inspects `exitCode`:

```dart
await Process.run('open', ['-a', 'Terminal', path]);
```

`open` reports "no such application" by exiting non-zero, not by throwing, so this is the identical
failure mode that made the VS Code bug invisible — still present, because it lives outside
`FileActions` and so was untouched by `11f9ed7`.

### F4 — An app's name is not its identity

Measured on this machine: the editor displayed as **Cursor** has the bundle identifier
`com.todesktop.230313mzl4w4u92`. Nothing about the name predicts the id.

`open -a <name-or-path>` resolves by name or path, so a stored name or path breaks when the app is
renamed, moved, reinstalled elsewhere, or when two installed apps share a display name. `open -b <id>`
resolves through Launch Services and survives all of those. The codebase has no bundle-id handling
today.

### F5 — The id can be read without new native code

An app bundle's `Contents/Info.plist` carries `CFBundleIdentifier`, readable directly (confirmed
against `/Applications/Cursor.app` while writing this record). `file_selector` is already a
dependency and already used to pick files from disk (`environment_health_sheet.dart:131`), so an
app picker needs no `NSWorkspace` channel and no new plugin.

### F6 — The settings machinery already fits this

`AppSettings` is a value with `copyWith`, one `static const _<name>Key` per setting and setters that
persist through `_persist((prefs) => …)` (`lib/core/settings/app_settings.dart:254-276, 513-519`).
`binPath_` is the existing precedent for "the user points at something on disk", and the settings
sheet already builds a per-tool control for it (`settings_sheet.dart:75`).

## Decision Drivers

* No hardcoded application may decide for the user — the defect this follows from.
* The app must keep working with **no** configuration: an unset preference behaves exactly as
  `11f9ed7` does now.
* A chosen application that later disappears must degrade usefully and say so, never silently.
* One place owns launching, so exit codes are checked once. `FileActions` already has the injectable
  launcher seam and a test file built on it.
* No new native channel if the same result is reachable from Dart.

## Considered Options

* **A — Two settings storing a bundle identifier**, "System default" for the editor and Terminal.app
  as the terminal's fallback.
* **B — Two settings storing an absolute `.app` path.**
* **C — Two settings storing the display name**, keeping `open -a <name>`.
* **D — No settings**: system default for files, terminal stays hardcoded.
* **E — A general "external applications" map** keyed by role, in the style of `binaryOverrides`.

## Decision Outcome

Chosen option: **"A — two settings storing a bundle identifier"**, because it is the only spelling of
the preference that survives an app being moved or renamed (F4), it keeps the no-configuration path
identical to today's fixed behaviour, and it needs no native code (F5).

Concretely:

* `AppSettings` gains `preferredEditorBundleId` and `preferredTerminalBundleId` (both `''` by
  default), each paired with a `…Name` string used **only** for display, so the UI can show "Cursor"
  while the launch uses the id.
* `FileActions.openFiles` prepends `-b <id>` when an editor is set. If that exits non-zero it falls
  back to the existing chain — default application, then `open -t` — and reports once that the chosen
  editor could not be used, naming it. Unset, the behaviour is byte-for-byte today's.
* `openInTerminal(path)` **moves into `FileActions`**: `open -b <id> <path>` when set, else
  `open -a Terminal <path>`, with the exit code checked and a failure thrown like `openFiles`, so the
  caller's `runAction` surfaces it. This closes F3 as part of the same change rather than leaving a
  second copy of the bug.
* Settings gains an "Opening files" section with two rows, each showing the current choice with
  **Choose…** (a `file_selector` pick filtered to `.app`) and **Reset to default**. Choosing reads
  `CFBundleIdentifier` from the bundle; a pick without one is **refused with a message** rather than
  silently stored as a path.
* `revealInFinder` keeps `open -R` unchanged: Finder is the file manager, and no choice is implied.

Terminal.app is the terminal's fallback because it is the one terminal macOS guarantees is present —
a last resort, not a preference.

### Consequences

* Good, because the user's editor and terminal are honoured, and neither is anyone's hardcode.
* Good, because an unconfigured install behaves exactly as the fixed code does today, so the setting
  can be ignored entirely.
* Good, because both launch paths end up in `FileActions`, where exit codes are already checked and
  the seam makes tests cheap — no application is ever launched by the suite.
* Neutral, because the stored id is opaque (`com.todesktop.230313mzl4w4u92`), which is why the
  display name is stored beside it.
* Bad, because a preference is another thing to migrate and to keep coherent: an app uninstalled
  after being chosen leaves a setting that resolves to nothing until the user resets it. The fallback
  makes that survivable, and the "could not use your chosen editor" message makes it visible.

### Confirmation

Every test below drives `FileActions`' injected launcher, so nothing is launched by the suite:

* a chosen editor launches as `open -b <id> <paths>`;
* a chosen editor that no longer resolves falls back to the default application, then to `open -t`,
  and reports once, naming the app;
* **unset behaves exactly as today** — this is the regression guard on `11f9ed7`, and it must be run
  against a tree with the preference plumbing removed to be trusted;
* a chosen terminal launches as `open -b <id> <path>`; unset launches Terminal.app;
* a non-zero exit from the terminal launch is reported, not swallowed (the F3 guard, seen to fail
  against the current `_openInTerminal`);
* both settings round-trip through `SharedPreferences` and survive a restart;
* an `.app` with no `CFBundleIdentifier` is refused at pick time and stores nothing.

Manually, on the maintainer's machine: "Open file" with no preference opens the per-type default;
with Cursor chosen it opens Cursor; "Open in Terminal" opens the chosen terminal rather than
Terminal.app.

## Pros and Cons of the Options

### A — Bundle identifier

* Good, because Launch Services resolves it wherever the app lives, so moving or reinstalling the app
  does not break the setting.
* Good, because it disambiguates two apps with the same display name.
* Good, because `CFBundleIdentifier` is readable from the picked bundle with no native code (F5).
* Neutral, because the stored value is unreadable to a human, so a display name must be stored too.
* Bad, because an app that ships a malformed `Info.plist` cannot be chosen at all — refused at pick
  time, which is at least immediate and explained.

### B — Absolute `.app` path

* Good, because it is the most literal thing to store and needs no plist read.
* Good, because a sandboxed pick already yields the path.
* Bad, because it breaks silently the moment the app moves — `/Applications` to `~/Applications`, or
  a reinstall — which is the same class of failure as the hardcode, only personalised.
* Bad, because the stored path is a machine detail that would be meaningless if settings were ever
  synced between machines.

### C — Display name with `open -a <name>`

* Good, because it is the smallest change and reads naturally in the UI.
* Bad, because name resolution is exactly what failed here: `open -a 'Visual Studio Code'` on a Mac
  without it. A renamed or duplicated app reproduces the original bug with the user's own choice.

### D — No settings

* Good, because it is free, and for files it is already correct: the per-type default is the user's
  expressed choice.
* Bad, because the terminal has no default to defer to (F2), so Terminal.app stays imposed on every
  iTerm/Warp/Ghostty user.
* Bad, because it leaves F3's discarded exit status in place.

### E — A general "external applications" map

* Good, because it matches `binaryOverrides`' shape and would absorb future roles (a diff tool, a
  merge tool) without new fields.
* Neutral, because the persistence cost is the same either way.
* Bad, because a map keyed by free-form role invites entries nothing reads, and the two roles that
  exist today have different defaults and different fallbacks — which two explicit fields state and a
  generic map hides.

## More Information

* **What this follows.** `11f9ed7` (open by type, `-t` fallback, failures reported) and the defect it
  fixed, `5e93607` / PR #4.
* **Code this record reads.** `lib/core/utils/file_actions.dart` (the launcher seam, `openFiles`,
  `revealInFinder`); `lib/features/worktrees/worktrees_view.dart:477-492` (`_revealInFinder`,
  `_openInTerminal`); `lib/core/settings/app_settings.dart` (fields, keys, `_persist`);
  `lib/features/settings/settings_sheet.dart` (sections, and the per-binary controls);
  `lib/features/settings/environment_health_sheet.dart:131` (the `file_selector` pick).
* **Not established.** Whether any terminal in common use needs more than a path argument to open at
  a directory — `open -b <id> <dir>` is assumed sufficient, as it is for Terminal.app, and a terminal
  that ignores the argument would need its own handling. Worth one manual check per terminal the
  maintainer actually uses before the plan is written.
* **No implementation exists.** This record proposes a decision; a plan follows only on approval.
