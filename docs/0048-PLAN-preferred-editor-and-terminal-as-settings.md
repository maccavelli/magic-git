---
status: "in-progress"
date: 2026-09-12
associated-madr: "0048-MADR-preferred-editor-and-terminal-as-settings.md"
---

# Implement: preferred editor and preferred terminal as settings

Associated MADR: [0048-MADR-preferred-editor-and-terminal-as-settings.md](0048-MADR-preferred-editor-and-terminal-as-settings.md)

## Goal

Let the user choose which application opens files and which opens a terminal, stored as a **bundle
identifier** and launched with `open -b`. Unset must behave byte-for-byte as `11f9ed7` does today:
the per-type default application, then `open -t`. Fold `Open in Terminal` into `FileActions` so both
launch paths check `open`'s exit status in one place.

## Scope

**In**

| File | Change |
| --- | --- |
| `lib/core/utils/app_bundle.dart` | **new** — read `CFBundleIdentifier` / `CFBundleName` from an `.app` |
| `lib/core/utils/file_actions.dart` | `bundleId` on `openFiles`; new `openInTerminal`; fallback chain |
| `lib/core/settings/app_settings.dart` | 4 fields, 4 prefs keys, `copyWith`, `_applyFromPrefs`, one setter |
| `lib/features/settings/settings_sheet.dart` | an "Opening files" section with two rows |
| `lib/features/worktrees/worktrees_view.dart` | `_revealInFinder` / `_openInTerminal` delegate to `FileActions` |
| `lib/features/repository/file_view.dart`, `repo_status_view.dart`, `common/image_diff_view.dart`, `viewer/viewer_window.dart` | pass the chosen editor |
| `test/app_bundle_test.dart` | **new** |
| `test/file_actions_test.dart`, `test/app_settings_test.dart`, `test/worktrees_view_test.dart` | extended |
| `test/settings_preferred_apps_test.dart` | **new** — the two sheet rows |
| `tool/mutations/0048-preferred-apps.json` | **new** catalogue |

**Out**

* Enumerating installed applications (would need an `NSWorkspace` channel); the picker is
  `file_selector`, already a dependency at **1.1.0**.
* Per-repository or per-file-type overrides — one editor, one terminal, app-wide.
* `revealInFinder`, which keeps `open -R`: Finder is the file manager and no choice is implied.
* Any change to `RemoteEditManager` beyond what it inherits from `FileActions`.
* Non-macOS platforms; macOS is the only target.

## Rules for every phase

1. **Deviations stop the work.** Anything this plan does not cover — a wrong step, a file not listed,
   a pre-existing defect — is reported with evidence, real resolutions and the cost of doing nothing,
   and waits for the maintainer. The docs are amended before work continues.
2. **Commits** use exactly `git commit --no-edit`. Code and docs are never in one commit. Nothing is
   pushed unless the maintainer asks in that same turn.
3. **The gate before every code commit:** `flutter analyze` clean; `dart format --output=none
   --set-exit-if-changed` on each staged `.dart` file; the phase's targeted tests; then `flutter test`
   in full. Exit statuses are captured in variables, never piped into a filter.
4. **Every new guard is seen to fail** against a deliberately broken copy in a detached scratch
   worktree (`git worktree add --detach`), never by dirtying the tree, and the failure output goes in
   the execution record.
5. **The mutation catalogue runs one at a time**, with no other `flutter test` of mine in progress.

## Implementation Steps

### Phase 0 — preconditions

0.1 `flutter --version | head -1` matches `FLUTTER_VERSION` in `build_macos.sh` (**3.47.2**), and
`flutter pub get --enforce-lockfile` says `Got dependencies!`.

0.2 Baseline, recorded in the execution record: `flutter test` in full (expect `+4065 ~3` or higher),
and `git status --short` empty.

### Phase 1 — bundle identity, in pure Dart

1.1 **New** `lib/core/utils/app_bundle.dart`:

```dart
/// Identity of a chosen macOS application: what launches it, and what to show.
class AppBundle {
  const AppBundle({required this.bundleId, required this.name});
  final String bundleId;
  final String name;
}

/// Reads `<app>/Contents/Info.plist` and returns its identity, or null when the
/// path is not an app bundle or carries no `CFBundleIdentifier` — the caller
/// refuses the pick rather than storing a path that `open -b` cannot use.
AppBundle? readAppBundle(String appPath);
```

Parse the plist without a new dependency: `Info.plist` is XML in every app shipped today, so read the
file and take the `<string>` following `<key>CFBundleIdentifier</key>` (same for `CFBundleName`,
falling back to the bundle's directory name minus `.app`). A **binary** plist (`bplist00` magic) is
returned as `null` — refused, not guessed.

1.2 **New** `test/app_bundle_test.dart`, building fixture bundles under `Directory.systemTemp`:

* `reads the identifier and display name from an app bundle`
* `falls back to the bundle's own name when CFBundleName is absent`
* `a directory that is not an app bundle is refused`
* `an Info.plist with no CFBundleIdentifier is refused`
* `a binary Info.plist is refused rather than guessed`

1.3 Gate (rule 3), then **commit (code)**.

### Phase 2 — `FileActions` honours a chosen application

2.1 `lib/core/utils/file_actions.dart`:

```dart
Future<void> openFiles(List<String> absolutePaths, {String bundleId = ''});
Future<void> openInTerminal(String path, {String bundleId = ''});
```

`openFiles` launch order — each step only on a non-zero exit from the one before:

1. `open -b <bundleId> <paths…>` — only when `bundleId` is non-empty;
2. `open <paths…>` — the per-type default (today's first step);
3. `open -t <paths…>` — the default text editor;
4. throw `FileOpenException`.

`openInTerminal` launch order: `open -b <bundleId> <path>` when set, else `open -a Terminal <path>`;
a non-zero exit throws `FileOpenException`. Terminal.app is the fallback because it is the one
terminal macOS guarantees exists (MADR 0048 F2).

2.2 When step 1 fails but a later step succeeds, the chosen app could not be used. `FileActions`
reports that exactly once per call through a new optional `void Function(String message)? onNotice`
constructor parameter (default null), with the message `Could not open with <name or id> — used the
system default instead.` Nothing is thrown: the file did open.

2.3 Extend `test/file_actions_test.dart` (the existing `_Launcher` double; no application is ever
launched):

* `a chosen editor is launched by bundle id`
* `a chosen editor that no longer resolves falls back to the default application`
* `a chosen editor that no longer resolves reports once, naming it`
* `with no editor chosen the launch is exactly the system default chain` — **the regression guard on
  `11f9ed7`**
* `a chosen terminal is launched by bundle id`
* `with no terminal chosen Terminal.app is used`
* `a terminal that will not launch is reported, not swallowed`

2.4 **Seen to fail** (rule 4), in a scratch worktree: (a) drop the `bundleId` branch → the chosen-app
tests fail; (b) make `openInTerminal` ignore `exitCode` → the terminal guard fails. Both failures go
in the record.

2.5 Gate, then **commit (code)**.

### Phase 3 — the settings themselves

3.1 `lib/core/settings/app_settings.dart`, mirroring the existing shape exactly:

* fields (block at 17–129): `preferredEditorBundleId`, `preferredEditorName`,
  `preferredTerminalBundleId`, `preferredTerminalName`, each `String`, each defaulting to `''`;
* `copyWith` (139–160): four nullable parameters;
* keys (254–276): `_editorBundleIdKey = 'preferredEditorBundleId'`,
  `_editorNameKey = 'preferredEditorName'`, `_terminalBundleIdKey = 'preferredTerminalBundleId'`,
  `_terminalNameKey = 'preferredTerminalName'`;
* `_applyFromPrefs` (333–390): four `prefs.getString(...)` reads passed to `copyWith`;
* one setter, shaped like `setWorktreeDefaults` (580–604):

```dart
Future<void> setPreferredApps({
  AppBundle? editor,      // null leaves it; AppBundle('', '') clears it
  AppBundle? terminal,
}) async { … _userEdited = true; state = state.copyWith(…); await _persist(…); }
```

3.2 Extend `test/app_settings_test.dart` (harness: `SharedPreferences.setMockInitialValues` +
`ProviderContainer`):

* `preferred applications default to empty, meaning the system default`
* `a stored preferred editor and terminal load from prefs`
* `setPreferredApps persists both, and clearing one leaves the other`

3.3 `test/settings_bus_sync_test.dart` already covers the cross-isolate reload; confirm it still
passes unchanged — the new keys travel through the same `_applyFromPrefs`, so no code is added for it.

3.4 Gate, then **commit (code)**.

### Phase 4 — wiring the choice through to the launches

4.1 The five call sites pass the stored editor. Each already has `ref`:

| File | Line (at `11f9ed7`) |
| --- | --- |
| `lib/features/repository/file_view.dart` | 268 |
| `lib/features/repository/repo_status_view.dart` | 3042 |
| `lib/features/common/image_diff_view.dart` | 421 |
| `lib/features/viewer/viewer_window.dart` | 589 |
| `lib/features/viewer/remote_edit_service.dart` | 115, 178 |

Each reads `ref.read(appSettingsProvider).preferredEditorBundleId` and passes it, going through
`ref.read(fileActionsProvider)` rather than the bare top-level helper. The top-level helpers stay for
compatibility; a follow-up may retire them.

4.2 `lib/features/worktrees/worktrees_view.dart`: `_revealInFinder` (477–483) and `_openInTerminal`
(485–492) delegate to `FileActions` — the terminal one passing
`preferredTerminalBundleId` — keeping their existing `showErrorDialog` on failure. The menu entries
at 524–534 are unchanged.

4.3 `onNotice` is wired to `outputLogProvider.logError` where a `ref` is at hand, so "used the system
default instead" is visible in the Output pane rather than only in a dialog.

4.4 Extend `test/worktrees_view_test.dart` (integration-tagged, real git): `Open in Terminal routes
through FileActions with the chosen terminal`, overriding `fileActionsProvider` with a recording
double so nothing launches.

4.5 Gate, then **commit (code)**.

### Phase 5 — the Settings rows

5.1 `lib/features/settings/settings_sheet.dart`: a new section built with
`_section(context, 'Opening files', blurb)`, holding two rows that mirror `_binaryRow` (523–…): a
fixed-width label, the current value (the stored name, or `System default` / `Terminal`), a
**Choose…** `InlineActionButton`, and **Reset**.

5.2 Choosing calls:

```dart
final picked = await openFile(
  acceptedTypeGroups: const [
    XTypeGroup(label: 'Applications',
        uniformTypeIdentifiers: ['com.apple.application-bundle']),
  ],
  initialDirectory: '/Applications',
);
```

`file_selector_macos` maps `uniformTypeIdentifiers` to `UTType` and onto
`panel.allowedContentTypes` (`FileSelectorPlugin.swift:107-127`), which is what makes an app bundle
selectable rather than traversable. The pick is passed to `readAppBundle`; a `null` result shows
`That application has no bundle identifier, so it cannot be launched reliably.` and stores nothing.

5.3 **New** `test/settings_preferred_apps_test.dart`, pumping `SettingsSheet` the way
`settings_sheet_keymap_test.dart` does (`ProviderScope` → `MacosApp` → `pumpAndSettle`, with
`ensureVisible` before tapping):

* `the rows read System default and Terminal when nothing is chosen`
* `a stored choice is shown by name, not by bundle id`
* `Reset clears the stored choice`

5.4 **Manual, on the maintainer's Mac** — the one behaviour no unit test can reach (MADR 0048's
"not established"):

a. the picker lets an `.app` be **selected** rather than entered as a folder;
b. "Open file" with nothing chosen opens the per-type default; with Cursor chosen opens Cursor;
c. "Open in Terminal" opens the chosen terminal at the worktree directory;
d. a chosen app that has been deleted falls back and says so once.

**If (a) fails**, the panel is refusing bundle selection: that is a deviation, and the resolution to
offer first is `getDirectoryPath(initialDirectory: '/Applications')`, which returns the `.app`
directory path and feeds `readAppBundle` unchanged. Do not ship a hand-typed bundle id.

5.5 Gate, then **commit (code)**.

### Phase 6 — the sabotage catalogue

6.1 **New** `tool/mutations/0048-preferred-apps.json`, entries in the committed shape
(`label`, `file`, `find`, `replace`, `tests`), each removing exactly one guarantee:

| Label | Removes |
| --- | --- |
| `p2: the chosen editor is ignored` | the `-b` branch in `openFiles` |
| `p2: a failed chosen editor is not retried with the default` | the fallback step |
| `p2: the fallback is silent` | the `onNotice` call |
| `p2: the terminal launch ignores its exit status` | the `exitCode` check in `openInTerminal` |
| `p2: the terminal ignores the chosen app` | the `-b` branch in `openInTerminal` |
| `p1: a bundle without an identifier is accepted` | the null return in `readAppBundle` |
| `p3: the preferred apps never load from prefs` | the four `_applyFromPrefs` reads |
| `p3: setPreferredApps does not persist` | the `_persist` call |

6.2 `tool/mutate.py --check tool/mutations/0048-preferred-apps.json` reports every entry sound, then
`tool/mutate.py tool/mutations/0048-preferred-apps.json` must end
`N killed, 0 survived, 0 did not apply, 0 did not compile, 0 observed by no test`.

6.3 **Commit (code)** — the catalogue only.

### Phase 7 — close the records

7.1 MADR 0048 → `status: accepted`, `verified:` today. This plan → `status: complete` with its
execution record. README rows for 0048. **Commit (docs).**

## Execution Record

Approved and executed 2026-09-12. Seven commits, code and docs never mixed.

### Phase 0 — preconditions

`Flutter 3.47.2` matches `FLUTTER_VERSION` in `build_macos.sh`; `flutter pub get
--enforce-lockfile` resolved clean; the tree was clean at `5ae0b62`.

The **first** baseline run failed one test — `directory_watch_source_test.dart: an ordinary repo
watches exactly one root, as before`, `no matching path within 0:00:15.000000`. It passes alone. The
second full run was green: `03:35 +4065 ~3`. See deviation (a).

#### Deviation (a) — a pre-existing flaky test makes every gate a coin flip (2026-09-12, resolved)

**Found.** `test/directory_watch_source_test.dart` failed twice today under full-suite load, in two
*different* tests of that file (`an ordinary repo watches exactly one root, as before`, then `a commit
made IN the linked worktree is seen as a git-state change`), both with `no matching path within
0:00:15.000000` at its `waitFor` helper (lines 52-54). Run alone it passed every time: 5/5, three
separate runs. Its `waitFor` waits on a real `Directory.watch` event with a fixed 15-second ceiling
while roughly four thousand other tests compete for the same filesystem.

**Pre-existing.** Nothing in this plan touches that file, the watch source it exercises, or anything
it imports; the same flake appeared before the first line of Phase 1 was written.

**Resolutions.**

1. *Fix the wait under its own record.* The ceiling is a fixed clock where the test needs a signal —
   the same class of defect MADR 0044 removed from the watcher's arm. Cost: a record and a plan for a
   file outside this one's scope.
2. *Leave it, and re-run the gate when it trips*, recording each occurrence. Cost: nothing to build,
   but a green suite stops meaning "the code is good" and starts meaning "the dice were kind" — and a
   real regression in that file would be indistinguishable from the flake.

**The consequence of doing nothing:** every phase gate in this plan, and every one after it, carries a
false-failure rate nobody has measured. Two failures in five full runs today is the only data.

**Decision: resolution 1** (maintainer: "we need to resolve that"). It reached **three** failures
before it was addressed, always that file, always at the 15-second ceiling.

#### Deviation (a), executed — and the diagnosis corrected

~~The ceiling is a fixed clock where the test needs a signal.~~ That reading was wrong, and resolving
it began by disproving it. The timeout was never the defect: **the test was throwing the events away.**

`quietSource` handed back a **broadcast** stream. Each test then mutated the repository — `git add`,
`git commit` — and only subscribed afterwards, inside `waitFor`. A broadcast stream delivers to
whoever is listening at that instant and keeps nothing, so every event that arrived while git was
still running went to the keep-alive listener and was discarded. Nothing touches the repository after
that, so the wait sat on a silent watcher until its ceiling expired. On an idle machine git finishes
fast enough that some events land after the subscribe and the test passes; under load the whole burst
lands in the gap.

**Proved deterministically, with no load at all.** In a detached scratch worktree, a three-second
delay inserted between the git commands and the subscribe:

```text
no matching path within 0:00:15.000000
00:19 +0 -1: Some tests failed.
```

That is the identical failure seen three times under load, now on demand — which is what told us the
cause was a dropped event rather than a slow one.

**Fixed** by recording instead of racing: `quietSource` now returns a `_Reported`, which subscribes
the moment the source goes quiet — *before* the mutation — and `firstMatching` answers from what has
already arrived, falling back to waiting only when nothing matches yet. The 15-second timeout stays as
a backstop for a watcher that never reports at all; it is no longer the mechanism by which a report is
caught.

**Confirmed** with the same three-second delay that had failed every time, now passing:

```text
with the delay, the one test:   00:04 +1: All tests passed!
with the delay, all five:       00:09 +5: All tests passed!
```

**Gate.** `dart format` clean, `flutter analyze` clean, the file alone `00:06 +5`, full suite
`03:33 +4085 ~3`. **Commit** `eb2a8c2`. No production code changed: the defect was in the test.

**What this closes.** The gates in this plan were never measuring what they appeared to; three of the
runs recorded above were coin flips. They pass now for a reason rather than by luck.

### Phase 1, executed

**Created.** `lib/core/utils/app_bundle.dart` — `AppBundle` (identifier plus display name) and
`readAppBundle`, which refuses a path that is not a bundle, an `Info.plist` without a
`CFBundleIdentifier`, and a **binary** plist rather than guessing at one. `test/app_bundle_test.dart`,
five tests.

**Seen to fail**, in a detached scratch worktree with only the refusal removed:

```text
Expected: null
  Actual: AppBundle:<AppBundle(Nameless, )>
without an identifier there is nothing `open -b` could use
```

**Gate.** `dart format` 0 changed, `flutter analyze` No issues, 5 targeted tests, full suite
`03:35 +4070 ~3`. **Commit** `9eda3e6`.

### Phase 2, executed

**Modified.** `FileActions.openFiles(paths, {bundleId})` runs the chain `open -b <id>` → `open` →
`open -t` → `FileOpenException`; `openInTerminal(path, {bundleId})` launches the chosen terminal or
Terminal.app and **checks the exit status**, which the `Process.run` it replaces did not.

*Made precise while executing:* step 2.2 says the notice fires when the chosen application failed. It
is emitted only once a **later step has succeeded** — emitted earlier it would claim "used the system
default instead" in the case where nothing opened at all and an exception is already the whole story.

*Carried along:* the two `FileActions` doubles in `test/remote_edit_service_test.dart` had to take the
new named parameter — a mechanical consequence of the signature, not new scope. `MockFileActions` now
also records the bundle id each open was asked for.

**Seen to fail** twice, each in a scratch worktree with one sabotage applied to an otherwise current copy:

```text
(a) the -b branch removed      Expected: [['open', '-b', 'com.example.editor', '/repo/a.dart']]
                               3 tests failed
(b) openInTerminal ignores exitCode
                               Expected: throws <Instance of 'FileOpenException'> …
                                 Actual: <Instance of 'Future<void>'>  Which: emitted <null>
```

**Gate.** analyze clean, 17 targeted tests, full suite `03:34 +4077 ~3`. **Commit** `b98b5ef`.

### Phase 3, executed — and a defect the guard caught

**Modified.** `AppSettings` gains the four fields, their four prefs keys, the `copyWith` parameters,
the four `_applyFromPrefs` reads and `setPreferredApps({editor, terminal})`, shaped like
`setWorktreeDefaults`. `test/app_settings_test.dart` gains three guards.

**The guard failed before it passed, and it was right to.** `AppSettings` overrides `==` and
`hashCode`, and four new fields added without extending them make a state that differs *only* in the
preferred applications compare **equal** to its predecessor — so Riverpod suppresses the notification
and every listener, the Settings rows included, never learns the choice changed. The load guard timed
out (`TimeoutException after 0:00:02.000000: Future not completed`) until both were extended.
`Object.hash` was already at its 20-argument ceiling, so the two map digests and the four new fields
are combined in one nested hash, commented as such.

**Seen to fail**, with only the four `_applyFromPrefs` reads removed: the same `TimeoutException`.

**Gate.** analyze clean, 19 targeted tests, full suite `03:34 +4080 ~3`. **Commit** `39eb4b8`.

### Phase 4, executed

**Modified.** The five call sites (`file_view.dart`, `repo_status_view.dart`, `image_diff_view.dart`,
`viewer_window.dart`, and both opens in `remote_edit_service.dart`) read
`preferredEditorBundleId` and go through `fileActionsProvider`. `worktrees_view.dart` delegates
`_revealInFinder` and `_openInTerminal` to `FileActions` — passing `preferredTerminalBundleId` — and
no longer imports `dart:io`, because it no longer runs a process of its own. `fileActionsProvider`
wires `onNotice` to the Output pane.

**Created.** `Open in Terminal routes through FileActions with the chosen terminal` in
`worktrees_view_test.dart`, over a recording `FileActions`, a connection pinned local, and settings
built directly rather than loaded.

**Seen to fail**, with only the chosen terminal dropped from the call:

```text
Expected: 'com.googlecode.iterm2'
  Actual: ''
the stored choice reaches the launch
```

**Gate.** analyze clean, 148 targeted tests, full suite `03:31 +4081 ~3`. **Commit** `b79eb4c`.

### Phase 5, executed — except 5.4

**Created.** An "Opening files" section in `settings_sheet.dart` with two rows built on the existing
`_rowLabelled`, each showing the chosen application's **name** (or `System default` / `Terminal`),
with Choose… and Reset; Reset is disabled while nothing is chosen. The picker is
`openFile(acceptedTypeGroups: [XTypeGroup(uniformTypeIdentifiers: ['com.apple.application-bundle'])],
initialDirectory: '/Applications')`, and a pick whose bundle has no identifier is refused with a
message and stores nothing. `build` now *watches* the settings, so a fresh choice shows without
closing the sheet. `test/settings_preferred_apps_test.dart`, three tests.

**Seen to fail**, with only the fallback labelling dropped:

```text
Expected: exactly one matching candidate
  Actual: _TextWidgetFinder:<Found 0 widgets with text "System default": []>
```

**Gate.** analyze clean, 8 targeted tests, full suite `03:35 +4084 ~3`. **Commit** `99fab68`.

**5.4 is outstanding.** The manual checks are the maintainer's: that the panel lets an `.app` be
selected rather than traversed, that an unset editor opens the per-type default and a chosen one opens
the choice, that the chosen terminal opens at the worktree directory, and that a deleted chosen
application falls back and says so once. Acceptance criterion 11 waits on them, and with it this
plan's status.

### Phase 6, executed

**Created.** `tool/mutations/0048-preferred-apps.json`, eight entries. Every `find` string was
asserted to occur exactly once in its file before the catalogue was written.

```text
tool/mutate.py --check tool/mutations/0048-preferred-apps.json
                                 8 entries in 1 catalogue(s): 8 sound, 0 did not apply, 0 do not compile (0m 46s)
tool/mutate.py tool/mutations/0048-preferred-apps.json
                                 8 killed, 0 survived, 0 did not apply, 0 did not compile, 0 observed by no test
```

No Dart changed in this commit, so the suite was not re-run for it; the catalogue itself ran the
affected test files eight times, each in its own isolated worktree. **Commit** `aed271c`.

### Acceptance criteria

| # | Result |
| --- | --- |
| 1 | **Met.** `grep -rn "open', \['-a'" lib` returns one line: `openInTerminal`'s Terminal.app fallback, with its comment |
| 2 | **Met.** `with no editor chosen the launch is exactly the system default chain`, which also asserts no notice is emitted |
| 3 | **Met.** `a chosen editor is launched by bundle id` |
| 4 | **Met.** the fallback and the once-only notice, both guarded and both seen to fail |
| 5 | **Met.** `openInTerminal` lives in `FileActions`, checks `exitCode`, and `worktrees_view.dart` contains no `Process.run` — nor `dart:io` |
| 6 | **Met.** the round-trip guard passes, and `settings_bus_sync_test.dart` passes unchanged |
| 7 | **Met.** both refusals guarded in `app_bundle_test.dart`, and the sheet refuses the pick with a message |
| 8 | **Met.** `the rows read System default and Terminal when nothing is chosen` and `a stored choice is shown by name, not by bundle id` |
| 9 | **Met.** catalogue 0048: 8 killed, 0 survived, 0 did not apply |
| 10 | **Met.** analyze clean and the full suite green at every phase commit — with deviation (a)'s caveat on what a green suite currently proves |
| 11 | **Outstanding** — step 5.4 is the maintainer's to run |


## Verification

The whole-plan gate:

```sh
flutter --version | head -1                       # Flutter 3.47.2
flutter analyze                                   # No issues found
flutter test                                      # all pass
flutter test test/file_actions_test.dart test/app_bundle_test.dart \
  test/app_settings_test.dart test/settings_preferred_apps_test.dart \
  test/remote_edit_service_test.dart
tool/mutate.py --check tool/mutations/0048-preferred-apps.json
tool/mutate.py tool/mutations/0048-preferred-apps.json
```

Exit statuses are captured, never piped into a filter.

## Acceptance Criteria

1. No application name is hardcoded in a launch path. `grep -rn "open', \['-a'" lib` returns only
   `openInTerminal`'s Terminal.app fallback, with its comment.
2. With nothing chosen, the launched argv is exactly today's: `open <paths>`, then `open -t <paths>`.
   Guarded by `with no editor chosen the launch is exactly the system default chain`.
3. With an editor chosen, the first launch is `open -b <id> <paths>`.
4. A chosen application that no longer resolves falls back and is reported once, naming it.
5. `openInTerminal` lives in `FileActions`, checks `exitCode`, and `worktrees_view.dart` contains no
   `Process.run`.
6. Both settings round-trip through `SharedPreferences`, and `settings_bus_sync_test.dart` passes
   unchanged.
7. An `.app` without a `CFBundleIdentifier`, and a binary `Info.plist`, are both refused at pick time
   and store nothing.
8. The Settings rows show `System default` / `Terminal` when unset and the stored **name** when set.
9. Catalogue 0048 reports `0 survived, 0 did not apply`, and every other catalogue still does.
10. `flutter analyze` clean, full suite green, every staged Dart file formatted.
11. Step 5.4's manual checks pass on the maintainer's Mac, with (a)'s result recorded either way.

## Rollout and Rollback

Seven commits, code and docs never mixed. **The phases stack**: 2 needs 1's `readAppBundle`, 4 needs
2 and 3, 5 needs 4, 6 needs all of them.

Rollback reverts code commits newest-first (`git revert --no-edit <sha>`), never resets and never
rewrites history. **Nothing to clean up**: the only persisted state is four `SharedPreferences`
strings, and a build without the feature ignores them — an unset preference and a stranded preference
both mean "system default".

Nothing is pushed unless the maintainer asks in that same turn.

## Risks

* **The panel may refuse to select an `.app`.** Step 5.4(a) is the check, and `getDirectoryPath` is
  the named resolution. This is the only step whose outcome the suite cannot establish.
* **Reading `Info.plist` inside a sandboxed pick.** The app is sandboxed with
  `files.user-selected.read-write` (`macos/Runner/Release.entitlements`, never modified by this work);
  the read is inside the selected bundle. If it is denied, that is a deviation, and the resolution to
  offer is reading the identity in the same tick as the pick, while the grant is live.
* **A terminal that ignores a directory argument.** MADR 0048 records this as not established;
  step 5.4(c) is the check, per terminal the maintainer uses.
* **A binary `Info.plist`** would make an otherwise valid app unselectable. Refusing is deliberate —
  a wrong identifier fails at launch time, where the user cannot see why.
* **Five call sites gain a settings read.** `appSettingsProvider` is already read across the app; the
  risk is a missed call site, which criterion 1's grep is written to catch.
