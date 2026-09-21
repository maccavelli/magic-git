---
status: "in-progress"
date: 2026-09-21
associated-madr: "0063-MADR-adopt-impeller-renderer-on-macos.md"
verified: 2026-09-21  # every "proven at planning time" row below was run on this date
---

# Implement: adopt Impeller as the macOS renderer by declaration

Associated MADR: [0063-MADR-adopt-impeller-renderer-on-macos.md](0063-MADR-adopt-impeller-renderer-on-macos.md)
(including its Amendment 0063.1).

## Goal

Make Impeller the **declared** macOS renderer. The plan has four parts:

* Add `FLTEnableImpeller` = `<true/>` to `macos/Runner/Info.plist`.
* Pin that declaration with a test that has been seen to fail.
* Prove on the shipping artifact that the engine really selects Impeller.
* Run the MADR's on-device gate and record its results in a GATES record.

The MADR moves to `accepted` only when every acceptance criterion in §"Verification" holds.

## Scope

**Files this plan changes. Nothing else may change; any other file is a deviation.**

| File | Change | Phase |
|---|---|---|
| `macos/Runner/Info.plist` | Insert the 10-line block in Appendix A.3, after `NSPrincipalClass` | 1 |
| `test/macos_renderer_canon_test.dart` | **New.** The contents of Appendix A.1, byte for byte | 1 |
| `reports/0063-GATES-impeller-on-device.md` (under `docs/`; it does not exist until Phase 5) | **New.** The gate results, in the shape of Appendix B | 5 |
| `docs/decisions/0063-MADR-adopt-impeller-renderer-on-macos.md` | Frontmatter `status`, `date` and `verified` only | 5 |
| `docs/decisions/0063-PLAN-adopt-impeller-renderer-on-macos.md` | Frontmatter plus the §"Execution record" | 0–5 |
| `docs/README.md` | The 0063 decision row, and a new 0063 GATES row under Reports | 5 |

Phase 0 also commits three files already in the working tree:
`docs/reports/0062-REPORT-flutter-sdk-pin-currency.md`, the MADR, and this plan.

**Out of scope** (see the MADR):

* the SDK pin move;
* any feature-code change;
* making `integration_test/` runnable without a certificate (MADR Amendment 0063.1);
* the stale comments and line references listed in the MADR's §"Incidental findings";
* installing the build into `~/Applications`. The installed app is the maintainer's daily copy, and
  replacing it is their call.

## Conventions for executing this plan

1. **Variables.** `REPO` is the repository root. `S` is a scratch directory outside the repository,
   created once in step 0.1 and reused by every later step. `APP` is
   `"$REPO/build/macos/Build/Products/Release/Magic Git.app"`, the path `build_macos.sh:142`
   derives from `PRODUCT_NAME = Magic Git` in `macos/Runner/Configs/AppInfo.xcconfig:8`.
2. **Exit status is captured, never piped away.** Every command whose result decides anything runs as
   `CMD > "$S/<name>.log" 2>&1; echo "exit=$?"`, and the log is read in full before concluding. No
   `| head`, `| tail` or `| grep` sits between a command and its verdict.
3. **Expected results are exact.** Each step states the exact expected output or exit code. **Any
   mismatch is a deviation.** Stop, record it, and take it to the maintainer with evidence and
   resolution options, as the global *Plan deviations* rule requires. Do not continue past a
   mismatch, and never "fix" one by loosening a check.
4. **Tools come from Appendix A, verified by hash.** Step 0.2 extracts the Appendix A files and checks
   each SHA-256 against the table there. Do not retype them.
5. **Negative tests never touch the working tree.** They run in a scratch copy, as the global rule
   requires.
6. **Commits.** Commit at the end of each phase that changes files (Phases 0, 1 and 5), with exactly
   `git commit --no-edit`, then read back the hook-generated message with `git log -1 --format=%B`.
   Never push.
7. **The maintainer operates the GUI.** Phase 3 items are performed by the maintainer, or by an agent
   the maintainer is watching. The executor records each observation verbatim in the GATES record.

## Facts proven at planning time (2026-09-21)

Each row was established by running the named command or reading the named source on 2026-09-21.
Rows marked **E** can only be proven by running the built app. They are checked in the phase named,
and a mismatch there is a deviation.

| # | Assertion | How it was proven | Result |
|---|---|---|---|
| F1 | The pinned SDK is 3.47.2, and `flutter` on `PATH` matches it | `build_macos.sh:45`; `flutter --version` | `FLUTTER_VERSION="3.47.2"`; first line `Flutter 3.47.2 • channel stable • https://github.com/flutter/flutter.git` |
| F2 | The local SDK source is the 3.47.2 engine | `cat /opt/homebrew/share/flutter/bin/internal/engine.version` | `a804b261645ef8c13eb3d5c44a5c2fb0340c5539` |
| F3 | Without the key, the engine selects Impeller | `FlutterDartProject.mm:77-84` (local SDK) | Returns `YES` when `FLTEnableImpeller` is absent |
| F4 | SDF rendering is always on | `FlutterDartProject.mm:99-101`; `FlutterEngine.mm:688-690` | `enableSDFs` returns `YES`, and the engine pushes `--impeller-use-sdfs=true` |
| F5 | The exact log line a macOS Impeller launch prints | `embedder.cc:572-581` (the Metal path builds `EmbedderSurfaceMetalImpeller`); `embedder_surface_metal_impeller.mm:52-56` | `Using the Impeller rendering backend (MetalSDF).` |
| F6 | The Skia line, printed only when Impeller is off | `FlutterEngine.mm:684-686` | `Using the Skia rendering backend (Metal).` |
| F7 | On macOS the engine log goes to stderr, at a level shown by default | `fml/logging.cc:178-181` (`fprintf(stderr, …)` in the non-Android/iOS/Fuchsia branch); `fml/log_level.h:18` (`kLogImportant = 3`); `fml/log_settings.h:25` (default minimum `kLogInfo = 0`) | An `IMPORTANT` line reaches stderr |
| F8 | A release app ignores environment switches, so only the plist decides | `shell/platform/common/engine_switches.cc:18-39` | Switches are read only under `#ifndef FLUTTER_RELEASE` |
| F9 | Info.plist today: 16 keys, no `FLTEnableImpeller`, and the insertion anchor occurs once | `cat -n macos/Runner/Info.plist`; A.3's `assert text.count(ANCHOR) == 1` | Anchor at lines 37-38 |
| F10 | The A.3 edit keeps a valid plist, and the key reads back as `true` | A.3 run on a scratch copy; `plutil -lint`; `PlistBuddy -c 'Print :FLTEnableImpeller'` | `OK`; `true` |
| F11 | The new test fails red on the unmodified plist, for the right reason | A.1 in a scratch copy, before A.3 | exit 1; only the real-file test failed; `Actual: 'FLTEnableImpeller is not declared'`; 5 fixture tests passed |
| F12 | After the edit, the new test is green and analyzer- and format-clean | Scratch copy after A.3: `flutter test`, `flutter analyze`, `dart format --set-exit-if-changed` | `+6: All tests passed!`; `No issues found!`; `0 changed` |
| F13 | All three mutations fail the real-file test with their exact messages | A.4 against the scratch copy | `skia opt-out`, `duplicate` and `commented out`: each exit 1 with its expected message; restored green exit 0 |
| F14 | With both changes applied, the whole suite stays green | A `git clone` of HEAD `26c3243` with A.1 and A.3 applied: `flutter pub get --enforce-lockfile`, `flutter analyze`, `flutter test` | exit 0 each; `No issues found!`; `03:48 +4229 ~3: All tests passed!` (entry P-1) |
| F15 | The Debug configuration cannot be signed here, so no `flutter run -d macos` or `integration_test` | `security find-identity -v -p codesigning`; `grep -c DEVELOPMENT_TEAM macos/Runner.xcodeproj/project.pbxproj` | `0 valid identities found`; `0` |
| F16 | An unsigned release build signs with the unsandboxed unsigned entitlements | `build_macos.sh:208-218` writes `Local.xcconfig`, which `AppInfo.xcconfig:37` includes after `:27`, and `project.pbxproj:681` reads | `MG_RELEASE_ENTITLEMENTS = Runner/Release-unsigned.entitlements` |
| F17 | Build outputs are gitignored | `git check-ignore -v` | `/build/` (.gitignore:40), `/RemoteMagicGit-macos.zip` (:54), `Local.xcconfig` (:69), `**/Flutter/ephemeral/` (macos/.gitignore:2) |
| F18 | An unsandboxed app's `hw-debug.log` lands in the real home | `SecondaryWindowController.swift:17` uses `NSHomeDirectory()`; F16 means no sandbox | `~/hw-debug.log` |
| F19 | The vsync probe exists only in a `WINDOW_DIAGNOSTICS` build, with a fixed format | `secondary_window_main.dart:63-69, 540-566` | `vsync probe: <status> value=<v> …`, written 2 s after the History window opens; a healthy clock gives `completed value=1.0` |
| F20 | The shipped binary is arm64-only | `lipo -archs` on the installed binary | `arm64` |
| F21 | The fixture generator is deterministic and produces the history the gate needs | A.5 run twice into fresh directories | HEAD `d98ca40df2f6ddbd11df2c54baa613553c083c72` both times; 3116 commits, 29 merges, 4 worktrees; refuses an existing directory (exit 1) |
| F22 | A public repository supplies a long CI log through the app's own fetch command | A.6, which uses `gh run view --job <id> --log`, the command at `gh_service.dart:749`, over the 30 runs the Forge panel lists (`gh_service.dart:609-622`) | exit 0: `job=104212477125 name='Dependabot' lines=2968` on 2026-09-21. Exit 1 when below threshold was observed with a 5000-line threshold |
| F23 | The renderer launcher passes and fails correctly | A.7 against three stand-in binaries | Impeller stub: `PASS`, exit 0. Skia stub: `FAIL: Skia line present`, exit 1. Silent-exit stub: `FAIL: process exited with 3`, exit 1 |
| F24 | The probe reader passes and fails correctly | A.8 against a fake `HOME` | Frozen clock (`forward value=0.0`): exit 1. Healthy: exit 0. Rotated log: exit 0. A passing line written before `mark` is ignored |
| F25 | Palette labels and shortcuts the gate names | `keymap.dart:175-178, 282-287, 257-262, 557-575`; `command_palette.dart:343-362`; `app_settings.dart:585-586`; `worktrees_view.dart:514-517`; `local_repo_form.dart:92` | ⌘K Command Palette; ⌘⇧H Open History in New Window; ⌘⇧E Toggle File View; ⌘= / ⌘- / ⌘0 History zoom, clamped to 0.6–2.0; Worktrees row menu "Open in Window"; "Choose Folder…" |
| F26 | No Magic Git crash reports exist yet | `ls ~/Library/Logs/DiagnosticReports/` filtered to `Magic Git*` | 0 |
| F27 | The commit hook is the global one | `git rev-parse --path-format=absolute --git-path hooks` | `/Users/<user>/.global-git-hooks` |
| E1 | The built bundle carries the key | Phase 2, step 2.3 | — |
| E2 | The built app logs the Impeller line and not the Skia line | Phase 2, step 2.5 | — |
| E3 | Every gate item passes | Phases 3 and 4 | — |

## Implementation Steps

### Phase 0: preconditions and records (changes no source)

**0.1 Scratch directory and tools.**

```sh
cd <your magic-git checkout>
export REPO="$(git rev-parse --show-toplevel)"
export S="$(mktemp -d -t mg-0063)"; echo "S=$S"
```

Record the printed `S` in the execution record.

**0.2 Extract the Appendix A tools and verify their hashes.** Save the extractor in Appendix A.2 as
`$S/extract.py` and run it:

```sh
python3 "$S/extract.py" "$REPO/docs/decisions/0063-PLAN-adopt-impeller-renderer-on-macos.md" "$S/tools" > "$S/extract.log" 2>&1; echo "exit=$?"
```

Expected: `exit=0`, and the log has one `ok <name> <sha256>` line for each of the 8 files in the
Appendix A table.

**0.3 The SDK matches the pin.**

```sh
flutter --version > "$S/fv.log" 2>&1; echo "exit=$?"
flutter pub get --enforce-lockfile > "$S/pub.log" 2>&1; echo "exit=$?"
```

Expected: both `exit=0`. The first line of `fv.log` is exactly
`Flutter 3.47.2 • channel stable • https://github.com/flutter/flutter.git`, and `pub.log` contains
`Got dependencies!`.

**0.4 The commit hook is the global one.**
`git -C "$REPO" rev-parse --path-format=absolute --git-path hooks` prints the path ending
`/.global-git-hooks`.

**0.5 The working tree holds only the records.** ~~`git -C "$REPO" status --porcelain` prints exactly
these four lines, in any order:~~ *(Deviation D1: the maintainer committed the four records as
`9d8ed8a` before execution began. The expected output is now an empty `git status --porcelain`
with `9d8ed8a` at HEAD.)*

```
 M docs/README.md
?? docs/decisions/0063-MADR-adopt-impeller-renderer-on-macos.md
?? docs/decisions/0063-PLAN-adopt-impeller-renderer-on-macos.md
?? docs/reports/0062-REPORT-flutter-sdk-pin-currency.md
```

**0.6 Baseline: analyzer and suite green.**

```sh
cd "$REPO" && flutter analyze > "$S/analyze0.log" 2>&1; echo "exit=$?"
cd "$REPO" && flutter test > "$S/test0.log" 2>&1; echo "exit=$?"
```

Expected: both `exit=0`, `analyze0.log` ends `No issues found!`, and the last line of `test0.log`
contains `All tests passed!`.

**0.7 Commit the records.** ~~(as below)~~ *(Deviation D1: already satisfied by `9d8ed8a`, which
contains exactly these four files. There is nothing to commit, so this step was not run.)*

```sh
cd "$REPO" && git add docs/README.md docs/decisions/0063-MADR-adopt-impeller-renderer-on-macos.md \
  docs/decisions/0063-PLAN-adopt-impeller-renderer-on-macos.md docs/reports/0062-REPORT-flutter-sdk-pin-currency.md
git commit --no-edit > "$S/commit0.log" 2>&1; echo "exit=$?"; git log -1 --format=%B
```

Expected: `exit=0`, and `git status --porcelain` is empty afterwards.

### Phase 1: declaration and pinning test

**1.1 Red first.** Write `test/macos_renderer_canon_test.dart` as `$S/tools/macos_renderer_canon_test.dart`
(already hash-checked):

```sh
cp "$S/tools/macos_renderer_canon_test.dart" "$REPO/test/macos_renderer_canon_test.dart"
cd "$REPO" && flutter test test/macos_renderer_canon_test.dart > "$S/red.log" 2>&1; echo "exit=$?"
```

Expected: `exit=1`. `red.log` shows exactly one failing test,
`Info.plist declares FLTEnableImpeller = true exactly once`, with `Actual: 'FLTEnableImpeller is not declared'`,
and `+5 -1: Some tests failed.`. This is the test seen to fail on the real, unmodified file.

**1.2 Declare the renderer.**

```sh
python3 "$S/tools/edit_plist.py" "$REPO" > "$S/edit.log" 2>&1; echo "exit=$?"
plutil -lint "$REPO/macos/Runner/Info.plist"; /usr/libexec/PlistBuddy -c 'Print :FLTEnableImpeller' "$REPO/macos/Runner/Info.plist"
git -C "$REPO" diff --stat -- macos/Runner/Info.plist
```

Expected: `exit=0`; `…/Info.plist: OK`; `true`; `1 file changed, 10 insertions(+)`.

**1.3 Green.**

```sh
cd "$REPO" && flutter test test/macos_renderer_canon_test.dart > "$S/green.log" 2>&1; echo "exit=$?"
```

Expected: `exit=0`, with `+6: All tests passed!`.

**1.4 Seen to fail on the real file: the mutations, in a scratch copy.** The copy excludes `.git`.
That is safe here because A.4 runs only `test/macos_renderer_canon_test.dart`, which reads a file and
needs no repository. The full suite must **not** run in this copy: `docs_records_test.dart` shells
out to `git ls-files` (`tool/records.dart:66`), and it fails without `.git` (execution record P-1).

```sh
rsync -a --exclude build --exclude .dart_tool --exclude .git --exclude .flutter-sdk "$REPO/" "$S/copy/"
cd "$S/copy" && flutter pub get --offline > "$S/copy-pub.log" 2>&1; echo "exit=$?"
python3 "$S/tools/mutate.py" "$S/copy" > "$S/mutate.log" 2>&1; echo "exit=$?"; cat "$S/mutate.log"
```

Expected: both `exit=0`, and `mutate.log` is exactly:

```
skia opt-out: exit=1 expected-message=yes
duplicate: exit=1 expected-message=yes
commented out: exit=1 expected-message=yes
restored green: exit=0
```

**1.5 Pre-commit gate on the whole tree.**

```sh
cd "$REPO" && dart format --output=none --set-exit-if-changed test/macos_renderer_canon_test.dart > "$S/fmt.log" 2>&1; echo "exit=$?"
cd "$REPO" && flutter analyze > "$S/analyze1.log" 2>&1; echo "exit=$?"
cd "$REPO" && flutter test > "$S/test1.log" 2>&1; echo "exit=$?"
```

Expected: all three `exit=0`, and the last line of `test1.log` contains `All tests passed!`. The test
count is `test0`'s plus 6.

**1.6 Commit.** `git status --porcelain` lists exactly `M macos/Runner/Info.plist` and
`?? test/macos_renderer_canon_test.dart`~~. Stage those two, then~~ *(Deviation D1: plus
` M docs/decisions/0063-PLAN-adopt-impeller-renderer-on-macos.md`, which carries D1 and the
Phase 0–1 execution record. Stage those three, then)*
`git commit --no-edit > "$S/commit1.log" 2>&1; echo "exit=$?"`, which must print `exit=0`. The
Dart precommit hook may run on the staged test file; its failure blocks the commit and is a
deviation.

### Phase 2: build the shipping artifact and prove the renderer

**2.1 The maintainer quits every running Magic Git.** Then:

```sh
pgrep -f 'Magic Git.app/Contents/MacOS/Magic Git' > "$S/pgrep.log" 2>&1; echo "exit=$?"
```

Expected: `exit=1`, meaning no process. Never `pkill` or `kill` a process this plan did not start.

**2.2 Build unsigned; no install.**

```sh
cd "$REPO" && ./build_macos.sh --unsigned > "$S/build.log" 2>&1; echo "exit=$?"
cat "$REPO/macos/Runner/Configs/Local.xcconfig"; git -C "$REPO" status --porcelain
```

Expected:

* `exit=0`.
* `Local.xcconfig` is exactly `MG_RELEASE_ENTITLEMENTS = Runner/Release-unsigned.entitlements`.
* `git status --porcelain` is empty (F17).

**2.3 The bundle carries the declaration (E1).**
`/usr/libexec/PlistBuddy -c 'Print :FLTEnableImpeller' "$APP/Contents/Info.plist"` prints `true`.

**2.4 Architecture.** `lipo -archs "$APP/Contents/MacOS/Magic Git"` prints `arm64`. Any `x86_64` is
a deviation: the MADR scoped out Intel on the strength of F20.

**2.5 The runtime renderer (E2).** Record the crash-report baseline, then launch:

```sh
ls ~/Library/Logs/DiagnosticReports/ > "$S/crash-before.txt"; echo "exit=$?"
python3 "$S/tools/launch_and_check_renderer.py" "$APP/Contents/MacOS/Magic Git" "$S/app-stderr.log" > "$S/launch.log" 2>&1; echo "exit=$?"; cat "$S/launch.log"
```

Expected: `exit=0`, and `launch.log` shows
`PASS: [IMPORTANT:…embedder_surface_metal_impeller.mm(53)] Using the Impeller rendering backend (MetalSDF).`
followed by `pid=<n>`. Record `<n>` as `APP_PID`. Leave the app running for Phase 3.

### Phase 3: on-device gate (maintainer-operated, release artifact from Phase 2)

**3.0 Fixtures.**

```sh
python3 "$S/tools/make_fixture.py" "$S/fixture" > "$S/fixture.log" 2>&1; echo "exit=$?"; cat "$S/fixture.log"
python3 "$S/tools/pick_ci_job.py" > "$S/ci.log" 2>&1; echo "exit=$?"; cat "$S/ci.log"
```

Expected: `make_fixture.py` exits 0 and prints `head=d98ca40df2f6ddbd11df2c54baa613553c083c72`,
`commits=3116`, `merges=29` and `worktrees=4`. `pick_ci_job.py` exits 0 and names one job, with
`lines` ≥ 1500. Record the run, job and name. If `pick_ci_job.py` exits 1 (no log of 1,500 lines
among the 30 listed runs), G7 is a deviation, not a skip.

In the app, open the fixture with ⌘K, **Manage Connections**, then the This Mac repository form's
**Choose Folder…**, selecting `$S/fixture/repo`. Every item below uses that repository unless it
says otherwise.

For each item, record in the GATES record: **PASS** or **FAIL**, the observation verbatim, and a
screenshot path (`screencapture -x "$S/shots/G<n>-<step>.png"`). Screenshots stay in `$S`; they are
evidence for the executor, not committed content.

| Item | Steps | PASS when |
|---|---|---|
| **G1 Vibrancy punch-through** | (a) With the main window focused, look at the left sidebar. (b) ⌘K, **Go to Repository**, then ⌘⇧E (**Toggle File View**) until the Files pane is visible. (c) Drag the pane's resize handle 100 pt wider, then back. (d) Click another app so Magic Git is inactive. (e) Switch macOS appearance Light ↔ Dark (System Settings, Appearance). Flutter content stays dark by design (`tabs_host.dart:487-491`); only the native blur behind it follows the system. | In every state (a)–(e), both the sidebar and the Files pane show the desktop's blurred colour through them. Neither is ever solid black or a flat opaque fill. |
| **G2a History window (second engine)** | (a) ⌘⇧H. (b) In the History window, right-click the `Commit 2999` row: the context menu opens. Choose **Tag d98ca40…**, which opens a sheet (`history_view.dart:1069-1072`, `showMacosSheet` at :854). Dismiss it without creating a tag. | The window opens with content. The menu and the sheet each animate in fully, not frozen invisible, and the sheet dismisses. |
| **G2b Detached windows** | ⌘K, **Go to Worktrees**. For each of `wt-a`, `wt-b` and `wt-c`, open the row's context menu and choose **Open in Window**. | Three extra windows open, each rendering its worktree. With G2a's History window that makes five windows open at once. None is blank or corrupt. |
| **G3 #185394 repro** | (a) Cmd-Tab away from and back to Magic Git 20 times. (b) Toggle full screen (⌃⌘F), Cmd-Tab away and back, and exit full screen; repeat 5 times (the #192829 repro). (c) Drag the main window across the edge onto another display and back, 5 times. (d) Unplug one external display and plug it back in. Count displays first with `system_profiler SPDisplaysDataType > "$S/displays.txt"` and count the `Resolution:` lines; with fewer than 2, (c) and (d) are recorded **N/A (1 display)**. | The process is alive (`ps -p $APP_PID` exits 0), and `ls ~/Library/Logs/DiagnosticReports/` diffed against `crash-before.txt` shows no new `Magic Git*` file. |
| **G4 Blurred minimap** | ⌘K, **Go to History**. Scroll the 3,116-commit list from top to bottom with the scroll bar and trackpad, watching the minimap strip. | The minimap shows a soft, continuous density wash with no hard banding or black blocks, and follows the scroll without visible stutter. |
| **G5 Commit graph under zoom** | In History, press ⌘0, then ⌘- 4 times (zoom 0.6), then ⌘= 14 times (zoom 2.0), then ⌘0. Inspect the lanes around any `Merge side-…` commit at each stop. | At 0.6, 1.0 and 2.0 the lane lines and merge curves are continuous, with no gaps, doubled strokes or jagged segments, and the nodes are round. |
| **G6 Monospace text** | In History, select `Commit 2999` and view the diff of `src/fixture.go`. Also open the Output view (⌘K, **Toggle Output View**). | Menlo glyphs are uniform in weight, with no clipped descenders or ascenders and no overlapping lines. |
| **G7 Large paragraph** | With the fixture open (its `origin` is `https://github.com/percona/percona-postgresql-operator.git`, set by A.5), ⌘K, **Go to Forge**. Open the run and job recorded in 3.0, scroll the log to the end, then click in it and press ⌘A. | The log renders in full. Scrolling to the end and selecting all text each complete within 2 s, with no beachball. |
| **G8 Drag ghost** | In History, press on any commit row and drag it at least 40 pt without releasing. | The dragged item is the **row snapshot**, showing the graph lane and date columns, not a text-only label (`drag_item.dart:161-185`). |
| **G9 Images** | Select `Commit 2999`, open `img/picture.png`'s image diff, and switch through each mode, including overlay and slider (`image_diff_view.dart:291-332`). Open `img/logo.svg` and `img/picture.png` in the viewer. | Both PNG versions render: blue with a light stripe before, orange with a dark stripe after. Overlay blends them and the slider splits them. The SVG shows a masked blue-to-pink gradient circle, a thin curve and the word `fixture`. |
| **G10 Memory baseline** | With the main window, History and the three detached windows open: `footprint -p $APP_PID > "$S/footprint.txt" 2>&1; echo "exit=$?"` | `exit=0`. Record the `Footprint:` line verbatim as the Impeller baseline. This item records a value and has no threshold (MADR §"Confirmation", item 3). |

**3.x Close.** Quit the app through its menu (⌘Q). Then `ps -p $APP_PID` must exit 1. Diff
`ls ~/Library/Logs/DiagnosticReports/` against `crash-before.txt` once more and record the result.

### Phase 4: vsync probe under Impeller (diagnostics build)

**4.1 Build the diagnostics variant.** Phase 2 rewrote `Local.xcconfig` to the unsigned selection,
and `flutter build` reads the same file. The build guide's warning about a plain `flutter build`
applies to signed builds.

```sh
cat "$REPO/macos/Runner/Configs/Local.xcconfig"
cd "$REPO" && flutter build macos --release --dart-define=WINDOW_DIAGNOSTICS=true > "$S/build-diag.log" 2>&1; echo "exit=$?"
```

Expected: the first command prints `MG_RELEASE_ENTITLEMENTS = Runner/Release-unsigned.entitlements`;
the build prints `exit=0`.

**4.2 Run the probe.**

```sh
python3 "$S/tools/read_vsync_probe.py" mark "$S/probe.state"
python3 "$S/tools/launch_and_check_renderer.py" "$APP/Contents/MacOS/Magic Git" "$S/app-stderr-diag.log" > "$S/launch-diag.log" 2>&1; echo "exit=$?"
```

Expected: `exit=0`. Open the fixture as in 3.0, press ⌘⇧H, and wait 5 s. Then:

```sh
python3 "$S/tools/read_vsync_probe.py" check "$S/probe.state" > "$S/probe.log" 2>&1; echo "exit=$?"; cat "$S/probe.log"
```

Expected: `exit=0`, and `probe.log` ends `PASS`. Record every printed `frame timings[…]` line
verbatim. A non-zero `vsyncStart` means the embedder clock now advances on its own, which
`secondary_window_binding.dart:18-20` says to note. That is information for a later cleanup, not
part of this gate. Quit the app with ⌘Q.

**4.3 Restore the shipping artifact.** Run `./build_macos.sh --unsigned` again, exactly as in 2.2, so
`build/` no longer holds a diagnostics build. Then repeat 2.3 and check `git status --porcelain` is
empty.

### Phase 5: records and acceptance

**5.1 GATES record.** Create `reports/0063-GATES-impeller-on-device.md` under `docs/` in the shape of
Appendix B. It records every result of 2.3–2.5, G1–G10, 3.x and 4.2 verbatim, and replaces this
machine's user name in any path with `<user>` (global rule *Internal identifiers*). Frontmatter:
`status: "complete"`, `date` and `verified` set to the execution date.

**5.2 Status changes, only if every row in §"Verification" holds.**

* In the MADR frontmatter, set `status: "accepted"`, and set `date` and `verified` to the execution
  date.
* In this plan's frontmatter, set `status: "complete"`, and set `date` and `verified` to the execution
  date.
* In `docs/README.md`, change the 0063 decision row's status to `accepted` and its plan cell's status
  from `proposed` to `complete`. Add under Reports:
  `| 0063 | [Impeller on-device gate](reports/0063-GATES-impeller-on-device.md) | \`complete\` |`.

If any gate item failed, none of these changes are made. Stop and prompt instead (§"Rollout and
Rollback").

**5.3 Check the records, then commit.**

```sh
cd "$REPO" && dart run tool/records.dart check > "$S/records.log" 2>&1; echo "exit=$?"
cd "$REPO" && flutter test test/docs_records_test.dart > "$S/docs.log" 2>&1; echo "exit=$?"
```

Expected: both `exit=0`. Then stage exactly `docs/README.md`, the MADR, this plan and the GATES
record, and run `git commit --no-edit`, which must print `exit=0`.

## Verification

Acceptance criteria. **All must hold** for the plan to be `complete` and the MADR `accepted`.

| AC | Criterion | Evidence |
|---|---|---|
| AC1 | `Info.plist` declares `FLTEnableImpeller` = `<true/>` exactly once, and `plutil -lint` reports OK | 1.2 |
| AC2 | The canon test failed red on the unmodified plist, then passed | 1.1, 1.3 |
| AC3 | All three mutations failed the real-file test with their exact messages | 1.4 |
| AC4 | The full `flutter analyze` and `flutter test` suites are green after Phase 1 | 1.5 |
| AC5 | The built bundle's `Info.plist` has `FLTEnableImpeller` = `true`, and the binary is `arm64` | 2.3, 2.4 |
| AC6 | The release binary logs `Using the Impeller rendering backend (MetalSDF).` and never the Skia line | 2.5, 4.2 |
| AC7 | G1–G9 all PASS; G3's display sub-steps are PASS or N/A only by the display-count rule | Phase 3 |
| AC8 | G10 is recorded | Phase 3 |
| AC9 | No new `Magic Git*` crash report appeared at any point | 2.5 baseline, G3, 3.x |
| AC10 | The vsync probe reads `completed value=1.0` in the History window | 4.2 |
| AC11 | `tool/records.dart check` and `docs_records_test.dart` pass with the GATES record indexed | 5.3 |
| AC12 | Each phase that changed files ended in a `--no-edit` commit, and nothing was pushed | 0.7, 1.6, 5.3 |

## Rollout and Rollback

**Rollout.** Phase 1's commit is the only behaviour-bearing change, and on 3.47.2 it changes no
runtime behaviour: F3 shows Impeller is already selected. Phases 2–4 verify, and Phase 5 records.
Installing the verified build into `~/Applications` (`./build_macos.sh --unsigned --install`) is the
maintainer's decision, made after acceptance.

**On a gate failure (before acceptance).** This is a deviation. Stop. Give the maintainer:

* the evidence: the item, the observation, the screenshot path, and the log path;
* whether it reproduces on the unmodified tree. Reproduce by building the parent of the Phase 1
  commit in a scratch clone (`git clone "$REPO" "$S/pre"`, then `git -C "$S/pre" checkout HEAD~1`
  and `./build_macos.sh --unsigned` there). Since F3 means that build is also Impeller, a
  reproduction proves the failure predates this plan;
* resolution options that fix the cause (global *Plan deviations* rule). The Skia rollback is offered
  only if no app-level fix exists, as the MADR's Decision Outcome item 5 says.

**Rollback to Skia (after acceptance), a single commit:**

1. In `macos/Runner/Info.plist`, change the `<true/>` after `<key>FLTEnableImpeller</key>` to
   `<false/>`, and change the comment's first line to state the rollback and link the MADR amendment.
2. In `test/macos_renderer_canon_test.dart`, change the real-file expectation to require `<false/>`,
   and update the header comment.
3. Add an amendment to the MADR naming the trigger, the upstream `[Impeller]` issue filed, and the
   expiry: the rollback lasts until upstream removes the opt-out.
4. Verify on a built app that the launcher (A.7) now reports `FAIL: Skia line present`. That is the
   expected outcome for a rollback, and it is what proves the rollback took effect.

## Execution record

Record per step: date, command, exit code, the decisive output lines verbatim, and every deviation
as a dated entry (what was found, the decision, and any file added to scope), per the global *Plan
deviations* rule.

* **D1 (2026-09-21, deviation, step 0.5).**
  * **Found:** `git status --porcelain` printed nothing, where four uncommitted records were
    expected. `git log` showed `9d8ed8a` "docs(decisions): propose Impeller renderer adoption on
    macOS (MADR 0063)", committed by the maintainer at 08:57. It contains exactly
    `docs/README.md`, this MADR, this PLAN and `0062-REPORT-flutter-sdk-pin-currency.md`
    (1752 insertions). `git diff HEAD` was empty, and step 0.2's hash check passed against the
    committed plan.
  * **Decision (maintainer):** "Amend plan, fold in". Steps 0.5 and 0.7 are annotated above; 0.7
    was not run. Step 1.6 also stages this PLAN, so the deviation and the Phase 0–1 execution
    record land in Phase 1's commit.
  * **Scope:** no file added. This PLAN was already in scope for phases 0–5.
  * **MADR:** unchanged, since no decision, fact or assumption moved.

* **Phase 0 (2026-09-21).**
  * 0.1: `S=/var/folders/…/T/mg-0063.0sOswmLcD9` (a `mktemp -d` path).
  * 0.2: extractor `exit=0`; 8 of 8 `ok`, with hashes identical to the Appendix A table.
  * 0.3: `exit=0`. `Flutter 3.47.2 • channel stable • https://github.com/flutter/flutter.git`.
    `pub get --enforce-lockfile` `exit=0`, `Got dependencies!`.
  * 0.4: `/Users/<user>/.global-git-hooks`.
  * 0.5: see D1.
  * 0.6: `flutter analyze` `exit=0`, `No issues found!`. `flutter test` `exit=0`,
    `03:40 +4223 ~3: All tests passed!`.
  * 0.7: not run (D1).
* **Phase 1 (2026-09-21).**
  * 1.1: `exit=1`. The only failure was `Info.plist declares FLTEnableImpeller = true exactly once [E]`,
    with `Actual: 'FLTEnableImpeller is not declared'`, then `+5 -1: Some tests failed.`
  * 1.2: `exit=0`; `…/macos/Runner/Info.plist: OK`; `true`; `1 file changed, 10 insertions(+)`.
  * 1.3: `exit=0`, `+6: All tests passed!`.
  * 1.4: `pub get --offline` `exit=0`. `mutate.py` `exit=0`, with output
    `skia opt-out: exit=1 expected-message=yes` / `duplicate: exit=1 expected-message=yes` /
    `commented out: exit=1 expected-message=yes` / `restored green: exit=0`.
  * 1.5: `dart format` `exit=0`, `0 changed`. `flutter analyze` `exit=0`, `No issues found!`.
    `flutter test` `exit=0`, `03:39 +4229 ~3: All tests passed!`, which is 4223 + 6.
* **P-1 (2026-09-21, planning).** F14 was proven in two attempts:
  * **First attempt:** an `rsync` copy that excluded `.git`. `flutter analyze` was clean, but
    `flutter test` exited 1 with `+4225 ~3 -4`. All 4 failures were `docs_records_test.dart`, each
    `Bad state: git ls-files failed … not a git repository`, raised from `tool/records.dart:66`.
    That is an artifact of copying without `.git`, not of the change, and it is why step 1.4 runs
    only the canon test in its copy.
  * **Second attempt:** a real `git clone` of HEAD `26c3243`, with A.1 and A.3 applied, so that
    `git status` showed exactly ` M macos/Runner/Info.plist` and `?? test/macos_renderer_canon_test.dart`.
    Results: `pub get --enforce-lockfile` exit 0; `flutter analyze` exit 0, `No issues found!`;
    `flutter test` exit 0, `03:48 +4229 ~3: All tests passed!`.

## Appendix A: tools (extract with A.2; do not retype)

| # | File | SHA-256 |
|---|---|---|
| A.1 | `macos_renderer_canon_test.dart` | `2450770648f0262777cbcfab5c7485d3fb444e5ed7aae5798967183b7df0d135` |
| A.2 | `extract.py` | `09dcfccd80419f649e418c87de8ca549ab86fd7971ceaa0f3d3d08182694e0af` |
| A.3 | `edit_plist.py` | `32a56dce363feecf7a99d9a618c48356087a7a76bc2bec17943ba10ade667dea` |
| A.4 | `mutate.py` | `3ac100a5b473e2926a45174433af17db31aa77a09f5ec00c12a957d0fa548eb4` |
| A.5 | `make_fixture.py` | `ae3ef375498841d6ce817437243ab4da5f3c097d9d3c084961f8ed3531e0f878` |
| A.6 | `pick_ci_job.py` | `c0e360da5f99a21467aa3c61a3c9f7bb70b6c70f939b18410b39ac609f7152b1` |
| A.7 | `launch_and_check_renderer.py` | `abfa93cb4a2ecf4985e388ac5ffad4af0dcfbeabfb6c43c139a9f2ccd7d795b6` |
| A.8 | `read_vsync_probe.py` | `ee519dce272228a424a98e7f34f5916f523157c832137775b91d71af2b482d35` |

### A.1 `macos_renderer_canon_test.dart`

```dart
// The renderer is a declared property of the app, not an engine default
// (0063-MADR-adopt-impeller-renderer-on-macos.md). Flutter 3.47 made Impeller
// the macOS default, but a default can move again in any upgrade, and a stray
// edit to Info.plist would change the renderer with no other check noticing:
// `flutter test` renders with software Skia regardless of this key, so no
// widget test or golden can see which renderer the shipped app uses.
//
// `FLTEnableImpeller` must therefore appear exactly once, outside any XML
// comment, set to `<true/>`. Rolling back to Skia is a deliberate edit to BOTH
// Info.plist and this test, per the MADR's rollback clause.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _infoPlist = 'macos/Runner/Info.plist';
const _key = 'FLTEnableImpeller';

/// Why [plist] does not declare Impeller, or null when it does.
///
/// String matching, not an XML parser, for the same reason as
/// `macos_entitlements_canon_test.dart`: this suite runs on every platform and
/// `PlistBuddy` is macOS-only. Comments are stripped first so a commented-out
/// key never counts as a declaration.
String? _impellerDeclarationProblem(String plist) {
  final live = plist.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');
  final values = RegExp(
    '<key>$_key</key>\\s*(<[^>]+>)',
  ).allMatches(live).map((m) => m[1]!).toList();
  if (values.isEmpty) return '$_key is not declared';
  if (values.length > 1) return '$_key is declared ${values.length} times';
  final value = values.single;
  if (!RegExp(r'^<true\s*/>$').hasMatch(value)) {
    return '$_key is $value, not <true/>';
  }
  return null;
}

String _plist(String body) =>
    '<?xml version="1.0" encoding="UTF-8"?>\n'
    '<plist version="1.0">\n<dict>\n$body</dict>\n</plist>\n';

void main() {
  test('Info.plist declares FLTEnableImpeller = true exactly once', () {
    final plist = File(_infoPlist).readAsStringSync();
    expect(_impellerDeclarationProblem(plist), isNull);
  });

  group('the declaration check', () {
    test('accepts one live <true/>', () {
      expect(
        _impellerDeclarationProblem(
          _plist('\t<key>FLTEnableImpeller</key>\n\t<true/>\n'),
        ),
        isNull,
      );
    });

    test('rejects a missing key', () {
      expect(
        _impellerDeclarationProblem(_plist('')),
        'FLTEnableImpeller is not declared',
      );
    });

    test('rejects the Skia opt-out', () {
      expect(
        _impellerDeclarationProblem(
          _plist('\t<key>FLTEnableImpeller</key>\n\t<false/>\n'),
        ),
        'FLTEnableImpeller is <false/>, not <true/>',
      );
    });

    test('rejects a duplicate declaration', () {
      expect(
        _impellerDeclarationProblem(
          _plist(
            '\t<key>FLTEnableImpeller</key>\n\t<true/>\n'
            '\t<key>FLTEnableImpeller</key>\n\t<false/>\n',
          ),
        ),
        'FLTEnableImpeller is declared 2 times',
      );
    });

    test('ignores a key that only appears inside a comment', () {
      expect(
        _impellerDeclarationProblem(
          _plist('\t<!-- <key>FLTEnableImpeller</key><true/> -->\n'),
        ),
        'FLTEnableImpeller is not declared',
      );
    });
  });
}
```

The renderer canon test (Phase 1). It becomes `test/macos_renderer_canon_test.dart`.

### A.2 `extract.py`

```python
"""Extract the Appendix A tools from the 0063 PLAN and verify their SHA-256.

Usage: extract.py <plan.md> <dest-dir>

Each tool is a level-3 heading `A.<n> <name>` followed by one fenced block. The
block body plus a trailing newline is written to <dest-dir>/<name>, and its
hash must equal the one in the Appendix A table. Exits 1 on any mismatch.
"""
from __future__ import annotations

import hashlib
import re
import sys
from pathlib import Path

FENCE = "`" * 3  # spelled out so this file can itself sit inside a fenced block
BLOCK = re.compile(
    rf"^### (A\.\d+) `([^`]+)`\n\n{FENCE}\w*\n(.*?)\n{FENCE}$", re.M | re.S
)
ROW = re.compile(r"^\| (A\.\d+) \| `([^`]+)` \| `([0-9a-f]{64})` \|$", re.M)


def main() -> int:
    plan, dest = Path(sys.argv[1]), Path(sys.argv[2])
    text = plan.read_text()
    expected = {name: digest for _, name, digest in ROW.findall(text)}
    blocks = {name: body for _, name, body in BLOCK.findall(text)}
    dest.mkdir(parents=True, exist_ok=True)
    failures = 0
    for name, digest in expected.items():
        if name not in blocks:
            print(f"MISSING {name}")
            failures += 1
            continue
        data = (blocks[name] + "\n").encode()
        (dest / name).write_bytes(data)
        actual = hashlib.sha256(data).hexdigest()
        ok = actual == digest
        print(f"{'ok' if ok else 'MISMATCH'} {name} {actual}")
        failures += not ok
    if set(blocks) - set(expected):
        print(f"UNLISTED {sorted(set(blocks) - set(expected))}")
        failures += 1
    return 1 if failures or not expected else 0


if __name__ == "__main__":
    sys.exit(main())
```

The extractor. Save this one by hand as `$S/extract.py` (step 0.2); it re-extracts itself, so its own hash is checked too.

### A.3 `edit_plist.py`

```python
"""Insert the FLTEnableImpeller declaration into macos/Runner/Info.plist."""
from __future__ import annotations

import sys
from pathlib import Path

ANCHOR = "\t<key>NSPrincipalClass</key>\n\t<string>NSApplication</string>\n"
BLOCK = (
    "\t<!-- Renderer: Impeller, declared deliberately\n"
    "\t     (docs/decisions/0063-MADR-adopt-impeller-renderer-on-macos.md).\n"
    "\t     Flutter 3.47 made Impeller the macOS default; this key states the\n"
    "\t     choice so a future default change cannot move the renderer\n"
    "\t     silently. test/macos_renderer_canon_test.dart pins it. Rolling\n"
    "\t     back to Skia means false here AND an edit to that test, per the\n"
    "\t     MADR's rollback clause; upstream will remove the opt-out in a\n"
    "\t     future release. -->\n"
    "\t<key>FLTEnableImpeller</key>\n"
    "\t<true/>\n"
)


def main() -> None:
    path = Path(sys.argv[1]) / "macos/Runner/Info.plist"
    text = path.read_text()
    assert text.count(ANCHOR) == 1, "NSPrincipalClass anchor not found exactly once"
    assert "FLTEnableImpeller" not in text, "FLTEnableImpeller already present"
    assert "--" not in BLOCK.replace("<!--", "").replace("-->", ""), "'--' inside comment"
    path.write_text(text.replace(ANCHOR, ANCHOR + BLOCK))
    print(f"edited {path}")


if __name__ == "__main__":
    main()
```

Inserts the declaration into `macos/Runner/Info.plist` (step 1.2).

### A.4 `mutate.py`

```python
"""Run the renderer canon test against three broken Info.plist variants.

Operates on a scratch copy of the repository (argv[1]), never the working tree.
Each mutation must make the real-file test fail with its specific message; the
green plist is restored after every run and re-verified at the end.
"""
from __future__ import annotations

import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

LIVE = "\t<key>FLTEnableImpeller</key>\n\t<true/>\n"


@dataclass(frozen=True)
class Mutation:
    name: str
    old: str
    new: str
    expected: str


MUTATIONS = (
    Mutation("skia opt-out", LIVE, "\t<key>FLTEnableImpeller</key>\n\t<false/>\n",
             "'FLTEnableImpeller is <false/>, not <true/>'"),
    Mutation("duplicate", LIVE, LIVE + LIVE, "'FLTEnableImpeller is declared 2 times'"),
    Mutation("commented out", LIVE, "\t<!-- <key>FLTEnableImpeller</key><true/> -->\n",
             "'FLTEnableImpeller is not declared'"),
)


def run_test(root: Path) -> tuple[int, str]:
    result = subprocess.run(
        ["flutter", "test", "test/macos_renderer_canon_test.dart"],
        cwd=root, capture_output=True, text=True, timeout=600)
    return result.returncode, result.stdout + result.stderr


def main() -> int:
    root = Path(sys.argv[1])
    plist = root / "macos/Runner/Info.plist"
    green = plist.read_text()
    assert green.count(LIVE) == 1, "green plist must hold exactly one live declaration"
    failures = 0
    try:
        for m in MUTATIONS:
            assert green.count(m.old) == 1
            plist.write_text(green.replace(m.old, m.new))
            assert plist.read_text() != green, f"{m.name}: mutation did not land"
            code, out = run_test(root)
            killed = code != 0 and f"Actual: {m.expected}" in out
            print(f"{m.name}: exit={code} expected-message={'yes' if killed else 'NO'}")
            failures += not killed
    finally:
        plist.write_text(green)
    code, _ = run_test(root)
    print(f"restored green: exit={code}")
    return 1 if failures or code != 0 else 0


if __name__ == "__main__":
    sys.exit(main())
```

The three-mutation negative test, run in a scratch copy (step 1.4).

### A.5 `make_fixture.py`

```python
"""Build the deterministic Git fixture for the 0063 Impeller on-device gate.

Creates <dest>/repo with a 3,000-commit history (a merge every 100 commits),
a monospace source file, a PNG changed in the last commit, an SVG, and three
worktrees <dest>/wt-a, wt-b, wt-c. Re-running with the same <dest> refuses to
overwrite. Fixed dates and identities make every run produce identical SHAs.
"""
from __future__ import annotations

import argparse
import struct
import subprocess
import sys
import zlib
from pathlib import Path

COMMITS = 3_000
MERGE_EVERY = 100
EPOCH = 1_700_000_000
IDENT = "Fixture <fixture@example.invalid>"
ORIGIN = "https://github.com/percona/percona-postgresql-operator.git"
WORKTREES = ("wt-a", "wt-b", "wt-c")

SVG = b"""<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256" viewBox="0 0 256 256">
<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
<stop offset="0" stop-color="#0a84ff"/><stop offset="1" stop-color="#ff375f"/></linearGradient>
<mask id="m"><circle cx="128" cy="128" r="100" fill="white"/></mask></defs>
<rect width="256" height="256" fill="url(#g)" mask="url(#m)"/>
<path d="M40 200 C 90 40, 170 40, 216 200" stroke="#1d1d1f" stroke-width="1.5" fill="none"/>
<text x="128" y="136" font-family="Menlo" font-size="20" text-anchor="middle">fixture</text>
</svg>
"""


def png(width: int, height: int, rgb: tuple[int, int, int]) -> bytes:
    """A solid-colour 8-bit RGB PNG with a diagonal stripe, built with the stdlib."""
    rows = bytearray()
    for y in range(height):
        rows.append(0)  # filter: none
        for x in range(width):
            rows += bytes((255 - c for c in rgb)) if abs(x - y) < 4 else bytes(rgb)

    def chunk(kind: bytes, data: bytes) -> bytes:
        return (struct.pack(">I", len(data)) + kind + data
                + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF))

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header)
            + chunk(b"IDAT", zlib.compress(bytes(rows), 9)) + chunk(b"IEND", b""))


def source(i: int) -> bytes:
    """A Go-like file whose body changes every commit, for monospace diffs."""
    lines = [f"package fixture // revision {i}", ""]
    lines += [f"func step{n:04d}() int {{ return {n} * {i % 97} }} // {'x' * (n % 60)}"
              for n in range(200)]
    return ("\n".join(lines) + "\n").encode()


def data(payload: bytes) -> bytes:
    return b"data %d\n" % len(payload) + payload + b"\n"


def commit(ref: str, mark: int, when: int, message: str, files: dict[str, bytes],
           parent: int | None, merge: int | None = None) -> bytes:
    out = [b"commit %s\n" % ref.encode(), b"mark :%d\n" % mark,
           f"author {IDENT} {when} +0000\n".encode(),
           f"committer {IDENT} {when} +0000\n".encode(), data(message.encode())]
    if parent is not None:
        out.append(b"from :%d\n" % parent)
    if merge is not None:
        out.append(b"merge :%d\n" % merge)
    for path, blob in files.items():
        out.append(f"M 100644 inline {path}\n".encode() + data(blob))
    return b"".join(out)


def stream() -> bytes:
    parts: list[bytes] = []
    mark = 0
    head: int | None = None
    for i in range(COMMITS):
        mark += 1
        files = {"src/fixture.go": source(i)}
        if i == 0:
            files |= {"img/picture.png": png(256, 256, (52, 120, 246)),
                      "img/logo.svg": SVG, "README.md": b"# Impeller gate fixture\n"}
        if i == COMMITS - 1:
            files["img/picture.png"] = png(256, 256, (255, 159, 10))
        parts.append(commit("refs/heads/main", mark, EPOCH + i * 3600,
                            f"Commit {i:04d}", files, head))
        head = mark
        if i and i % MERGE_EVERY == 0:
            side = head
            for s in range(3):
                mark += 1
                parts.append(commit(f"refs/heads/side-{i:04d}", mark,
                                    EPOCH + i * 3600 + 60 * (s + 1), f"Side {i:04d}.{s}",
                                    {f"side/{i:04d}.txt": f"{i}.{s}\n".encode()}, side))
                side = mark
            mark += 1
            parts.append(commit("refs/heads/main", mark, EPOCH + i * 3600 + 600,
                                f"Merge side-{i:04d}", {}, head, merge=side))
            head = mark
    return b"".join(parts)


def git(repo: Path, *args: str, stdin: bytes | None = None) -> str:
    result = subprocess.run(["git", "-C", str(repo), *args], input=stdin,
                            capture_output=True, timeout=600)
    if result.returncode != 0:
        sys.exit(f"git {' '.join(args)} failed: {result.stderr.decode().strip()}")
    return result.stdout.decode()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dest", type=Path)
    dest: Path = parser.parse_args().dest
    repo = dest / "repo"
    if dest.exists():
        sys.exit(f"{dest} already exists; choose a fresh directory")
    repo.mkdir(parents=True)
    git(repo, "init", "-q", "-b", "main")
    git(repo, "fast-import", "--quiet", stdin=stream())
    git(repo, "reset", "-q", "--hard", "main")
    git(repo, "remote", "add", "origin", ORIGIN)
    for name in WORKTREES:
        git(repo, "worktree", "add", "-q", "-b", name, str(dest / name), "main")
    print(f"repo={repo}")
    print(f"head={git(repo, 'rev-parse', 'HEAD').strip()}")
    print(f"commits={git(repo, 'rev-list', '--count', 'main').strip()}")
    print(f"merges={git(repo, 'rev-list', '--count', '--merges', 'main').strip()}")
    listing = git(repo, "worktree", "list", "--porcelain").splitlines()
    print(f"worktrees={sum(line.startswith('worktree ') for line in listing)}")


if __name__ == "__main__":
    main()
```

The deterministic Git fixture (step 3.0).

### A.6 `pick_ci_job.py`

```python
"""Print the GitHub Actions job with the longest retrievable log among recent runs.

Uses the same command the app does to fetch a job log
(GhService, lib/core/github/gh_service.dart:749): `gh run view --job <id> --log`.
"""
from __future__ import annotations

import json
import subprocess
import sys
from dataclasses import dataclass

REPO = "percona/percona-postgresql-operator"
# The Forge panel lists exactly this many runs (GhService.workflowRuns, limit = 30).
RUNS = 30
MIN_LINES = 1_500


@dataclass(frozen=True)
class Job:
    run_id: int
    workflow: str
    job_id: int
    name: str
    lines: int


def gh(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["gh", *args], capture_output=True, text=True, timeout=300)


def must(*args: str) -> str:
    result = gh(*args)
    if result.returncode != 0:
        sys.exit(f"gh {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout


def log_lines(job_id: int) -> int | None:
    """Line count of a job's log, or None when GitHub no longer has it."""
    result = gh("run", "view", "--job", str(job_id), "-R", REPO, "--log")
    return result.stdout.count("\n") if result.returncode == 0 else None


def jobs() -> list[Job]:
    runs = json.loads(must("run", "list", "-R", REPO, "--limit", str(RUNS),
                           "--json", "databaseId,workflowName,status"))
    found: list[Job] = []
    for run in (r for r in runs if r["status"] == "completed"):
        detail = json.loads(must("run", "view", str(run["databaseId"]), "-R", REPO,
                                 "--json", "jobs"))
        for job in detail["jobs"]:
            lines = log_lines(job["databaseId"])
            if lines is not None:
                found.append(Job(run["databaseId"], run["workflowName"],
                                 job["databaseId"], job["name"], lines))
    return found


def main() -> None:
    candidates = jobs()
    if not candidates:
        sys.exit("no retrievable job logs in the most recent runs")
    best = max(candidates, key=lambda j: j.lines)
    print(f"run={best.run_id} workflow={best.workflow!r} job={best.job_id} "
          f"name={best.name!r} lines={best.lines}")
    if best.lines < MIN_LINES:
        sys.exit(f"longest log has {best.lines} lines, below {MIN_LINES}")


if __name__ == "__main__":
    main()
```

Picks the longest CI job log the Forge panel can show (step 3.0, G7).

### A.7 `launch_and_check_renderer.py`

```python
"""Launch a macOS app binary with stderr captured and assert its renderer line.

Usage: launch_and_check_renderer.py <binary> <log-file>

Exits 0 once the Impeller (MetalSDF) line appears, leaving the app running and
printing its PID; exits 1 on the Skia line, on early exit, or after 60 s.
"""
from __future__ import annotations

import subprocess
import sys
import time
from pathlib import Path

IMPELLER = "Using the Impeller rendering backend (MetalSDF)."
SKIA = "Using the Skia rendering backend"
TIMEOUT_S = 60.0


def main() -> int:
    binary, log = Path(sys.argv[1]), Path(sys.argv[2])
    if not binary.is_file():
        print(f"FAIL: no binary at {binary}")
        return 1
    with log.open("wb") as sink:
        proc = subprocess.Popen([str(binary)], stdout=sink, stderr=subprocess.STDOUT,
                                start_new_session=True)
    deadline = time.monotonic() + TIMEOUT_S
    while time.monotonic() < deadline:
        text = log.read_text(errors="replace")
        if SKIA in text:
            print(f"FAIL: Skia line present (pid {proc.pid} left running)")
            return 1
        if IMPELLER in text:
            line = next(l for l in text.splitlines() if IMPELLER in l)
            print(f"PASS: {line.strip()}")
            print(f"pid={proc.pid}")
            return 0
        if proc.poll() is not None:
            print(f"FAIL: process exited with {proc.returncode} before logging a renderer")
            return 1
        time.sleep(0.5)
    print(f"FAIL: no renderer line within {TIMEOUT_S:.0f} s (pid {proc.pid} left running)")
    return 1


if __name__ == "__main__":
    sys.exit(main())
```

Launches the app with stderr captured and checks the renderer line (steps 2.5, 4.2).

### A.8 `read_vsync_probe.py`

```python
"""Mark or check the History window's vsync probe in ~/hw-debug.log.

  read_vsync_probe.py mark  <state-file>   record the log's current size
  read_vsync_probe.py check <state-file>   scan only lines written since `mark`

`check` exits 0 when a new `vsync probe: completed value=1.0` line exists, and
prints every new `vsync probe` and `frame timings` line either way.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

LOG = Path.home() / "hw-debug.log"
PASS = re.compile(r"vsync probe: completed value=1\.0\b")
SHOW = re.compile(r"vsync probe:|frame timings\[")


def main() -> int:
    mode, state = sys.argv[1], Path(sys.argv[2])
    size = LOG.stat().st_size if LOG.exists() else 0
    if mode == "mark":
        state.write_text(str(size))
        print(f"marked {LOG} at {size} bytes")
        return 0
    start = int(state.read_text())
    if size < start:  # rotated at launch (1 MB cap): everything is new
        start = 0
    with LOG.open("rb") as f:
        f.seek(start)
        new = f.read().decode(errors="replace").splitlines()
    shown = [line for line in new if SHOW.search(line)]
    print("\n".join(shown) if shown else "(no probe lines since mark)")
    ok = any(PASS.search(line) for line in new)
    print("PASS" if ok else "FAIL: no 'vsync probe: completed value=1.0' since mark")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
```

Marks and checks the History window's vsync probe in `~/hw-debug.log` (step 4.2).

## Appendix B: GATES record shape

```markdown
---
status: "complete"
date: YYYY-MM-DD
verified: YYYY-MM-DD
---

# Impeller on-device gate — 0063

Plan: [0063-PLAN](../decisions/0063-PLAN-adopt-impeller-renderer-on-macos.md) ·
MADR: [0063-MADR](../decisions/0063-MADR-adopt-impeller-renderer-on-macos.md)

| Field | Value |
|---|---|
| Commit under test | <sha of the Phase 1 commit> |
| Flutter | <first line of fv.log> |
| Hardware / macOS | <sysctl -n machdep.cpu.brand_string> / <sw_vers -productVersion> |
| Displays | <count of Resolution: lines> |
| Bundle key | <2.3 output> |
| Architectures | <2.4 output> |
| Renderer line | <2.5 PASS line> |

| Item | Result | Observation (verbatim) | Evidence |
|---|---|---|---|
| G1 … G10 | PASS / FAIL / N/A | … | $S/shots/…, $S/…log |
| 3.x crash reports | none / <files> | … | … |
| 4.2 vsync probe | PASS / FAIL | <probe.log lines> | … |
```
