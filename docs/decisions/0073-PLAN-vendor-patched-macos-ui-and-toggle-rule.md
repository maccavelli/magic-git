---
status: "proposed"
date: 2026-09-26
associated-madr: "0073-MADR-hidden-sidebar-slides-off-screen-in-a-patched-macos-ui.md"
verified: 2026-09-26
---

# Implement the vendored patched macos_ui in Magic Git, and offer Toggle Sidebar only where it can act

Associated MADR:
[0073-MADR-hidden-sidebar-slides-off-screen-in-a-patched-macos-ui.md](0073-MADR-hidden-sidebar-slides-off-screen-in-a-patched-macos-ui.md)

Depends on: `0073-PLAN-macos-ui-hidden-sidebar-upstream-patch.md`, through its Phase 3 (the
change has passed its tests and its device check in the example app). Phase 2 here (the toggle
rule) does not depend on it and may land first.

## Goal

Magic Git builds against macos_ui 2.2.2 plus exactly the reviewed patch, vendored in the
repository. At the 640 pt minimum, and after toggling or drag-closing the sidebar, no sidebar and
no native material shows under the content. "Toggle sidebar" is offered, as a button and as the
View menu item, only where macos_ui can show the sidebar.

## Scope

**In scope:**
* **the fork:** branch `magic-git/2.2.2-hidden-sidebar` off tag `2.2.2`, carrying the patch's
  `lib/src/layout/window.dart` change only. Not its version bump, CHANGELOG entry or tests,
  which belong to 2.2.4 on `dev`;
* **Magic Git:**
  * `third_party/macos_ui/` (new): `lib/`, `macos/`, `pubspec.yaml`, `LICENSE` and `CHANGELOG.md`
    from that branch, plus `PATCHED.md` recording the provenance: upstream, fork, branch, commit,
    the change, and when to remove it. **Not `README.md`**: its two broken anchors fail
    `docs_records_test` (measured), and a path dependency does not need it;
  * `pubspec.yaml`: `dependency_overrides: macos_ui: path: third_party/macos_ui`;
  * `pubspec.lock`: the resolution the override produces (macos_ui's source only);
  * `analysis_options.yaml`: `- third_party/**` under `analyzer: exclude:`;
  * `lib/features/common/sidebar_geometry.dart` (new): `kSidebarMinWidth = 240`,
    `kSidebarMaxWidth = 380`, `kSidebarWindowBreakpoint = 760`, and
    `bool sidebarCanShow(double windowWidth) => windowWidth > kSidebarWindowBreakpoint;`,
    mirroring macos_ui's `isAtBreakpoint = width <= windowBreakpoint`;
  * `lib/features/app_shell.dart`: the `Sidebar` takes the three constants, and
    `'global.toggleSidebar'` maps to `_toggleSidebar` only when
    `sidebarCanShow(MediaQuery.sizeOf(context).width)`, and to `null` otherwise;
  * `lib/features/repository/repo_status_view.dart`: `onToggleSidebar` is passed only under the
    same condition. `RepositoryContextBar` already hides the button when it is `null`
    (`repository_context_bar.dart:115`), so that file does not change;
  * `macos/Runner/MainFlutterWindow.swift`: `validateMenuItem` returns
    `enabledActionIds.contains("global.toggleSidebar")` for `#selector(toggleSidebar(_:))`;
  * tests:
    * `test/hidden_sidebar_test.dart` (new);
    * `test/sidebar_geometry_test.dart` (new);
    * `test/repo_status_view_test.dart`;
    * `test/app_shell_test.dart`;
  * records: this plan, the MADR's status, `docs/README.md`, and `docs/architecture.md` (one
    paragraph: what is vendored, why, and when it goes).

**Out of scope:** an overlay sidebar at compact width; changing the breakpoint or the window
minimum; any other change to macos_ui; the `RunnerTests` target, which is the template stub
(`testExample` only) and cannot exercise `validateMenuItem`, so the menu rule is a device check.

## Facts this plan is built on (verified 2026-09-26)

Line references were checked by a script (36 of 36 anchors hold).

| Fact | Evidence |
|---|---|
| Tag `2.2.2` equals the published 2.2.2 package byte for byte | `lib/` and `pubspec.yaml` compared |
| macos_ui is a plugin with native code (`MacOSUiPlugin`; SwiftPM and a podspec under `macos/`) | `pubspec.yaml:27-31`; `macos/` |
| Magic Git has no `dependency_overrides` | `pubspec.yaml` |
| `analysis_options.yaml` excludes `build/**` and `macos/**` only | `:13-15` |
| The identifier and NUL scans walk `lib`, `test`, `docs`, `scripts`, `integration_test` (not `third_party`) | `no_real_identifiers_scan_test.dart:101`, `source_is_text_scan_test.dart:24` |
| `docs_records_test` checks links and anchors in every Markdown file in the repository | measured: it flagged the vendored `README.md` |
| The button shows only when `compact && onToggleSidebar != null` | `repository_context_bar.dart:115` |
| Only the Repository page passes `onToggleSidebar` | `repo_status_view.dart:1963` (the only use in `lib/`) |
| A `null` handler drops a global id from the published set | `app_shell.dart:1032-1035`, `:1050-1052` |
| The fixed Toggle Sidebar item is validated by `super`, never by `enabledActionIds` | `MainFlutterWindow.swift:429`, `:684-694` |
| `app_shell.dart` imports `repo_status_view.dart`, so the shared constants need their own file | `app_shell.dart:47` |
| The build uses the `flutter` on `PATH` when it is 3.47.2 | `build_macos.sh:46`, `:157-166` |
| The workspace goldens pump page fixtures, not `MacosWindow` | `workspace_golden_test.dart:316-330` |

**Measured in a scratch worktree of Magic Git `a31bbb9`**, with the 2.2.2 backport prototype
vendored:
* `flutter pub get`: exit 0. The `pubspec.lock` diff is macos_ui's `description`/`source` only,
  from hosted to `path: "third_party/macos_ui"`, `relative: true`. The version stays 2.2.2.
* `flutter analyze`: "No issues found!" with the exclude, and 82 issues without it, all in
  `third_party/macos_ui`.
* The pixel reproduction passes with the patch (probe at −240…0; pixel `#F6F6F6`, the window
  background). At the same commit without the override it failed (red).
* The full suite: `+4468 ~3 -1`. The one failure was `docs_records_test` on the vendored
  `README.md` (`#dialogs`, `#slider`). Without the README that test passes (+27).
* `./build_macos.sh --unsigned`: exit 0. It logged "macos_ui 2.2.2 from path third_party/macos_ui
  (overridden)" and resolved the vendored plugin through SwiftPM.

## Implementation Steps

Each phase ends with `flutter analyze`, the phase's tests, the full suite
(`flutter test > "$LOG" 2>&1`, judged on its exit status and a count of `[E]` lines), and one
commit (`git commit --no-edit`), staging files by name. A step that cannot be done as written is a
deviation: stop and prompt.

### Phase 0: records and the failing test

0.1. Records: this plan `in-progress`, the index row.
0.2. `test/hidden_sidebar_test.dart`, promoted from the review's scratch reproduction:
     * a `MacosWindow` with the geometry from `sidebar_geometry.dart`, a solid `0xFFFF0000`
       sidebar (a colour no page uses), and a `ContentArea` child;
     * pixels read from a `RepaintBoundary` at (100, 300);
     * the accent-colour channel stubbed as `add_existing_repo_sheet_test.dart` does, and a
       `pump(Duration.zero)` after each read.
     Cases:
     * 1200 pt: the pixel is red (the sidebar is shown);
     * 640 pt, and 900 pt after `toggleSidebar()`: the pixel is not red, and the probe is not
       hit-testable.
     It lands in Phase 1, together with `sidebar_geometry.dart`, so no commit carries a failing
     test.
0.3. **Seen to fail** on the current tree (pub's 2.2.2), on the two hidden cases (red at
     (100, 300)), as measured in the review. The 1200 pt case passes.

### Phase 1: the backport and the vendored copy

1.1. Fork: `git switch -c magic-git/2.2.2-hidden-sidebar 2.2.2`. Take the upstream plan's Phase 2
     commit `P` as a diff of `window.dart` alone:
     `git diff P^ P -- lib/src/layout/window.dart > "$SCRATCH/sidebar.patch"`, then
     `git apply --3way "$SCRATCH/sidebar.patch"`.
     * Proven on the review's prototype: a plain `git apply` fails at `window.dart:326`, because
       #588 changed the context there. `--3way` applies cleanly, and the result is byte-identical
       to the exact-edit backport that passed the tests on 2.2.2 (+16 lines, one file).
     * Checking out `dev`'s `window.dart` wholesale is not used, because it carries #588.
     Then `git diff 2.2.2 -- lib/src/layout/window.dart` is exactly the patch. The package's
     `flutter test` fails exactly 2.2.2's 10 baseline tests, compared as sets, and
     `flutter analyze --fatal-infos lib/src/layout/window.dart` is clean. Commit that file only,
     and record the commit.
1.2. Magic Git: `git -C ~/gitrepos/macos_ui archive <commit> lib macos pubspec.yaml LICENSE CHANGELOG.md | tar -x -C third_party/macos_ui`.
     Check the copy: `diff -r` against a fresh archive in the scratchpad reports nothing. Write
     `PATCHED.md`.
1.3. `pubspec.yaml`: the override. `analysis_options.yaml`: the exclude. `flutter pub get`: the
     `pubspec.lock` diff is exactly macos_ui's source (the review's diff).
     `flutter pub deps | grep macos_ui` shows the path.
1.4. Phase 0's test and `sidebar_geometry.dart` are added, and the test passes. **Mutation:** in a
     scratch worktree with the override removed, it fails on the two hidden cases.
1.5. `./build_macos.sh --unsigned`: exit 0, with the "(overridden)" line in its log.
1.6. Checks: the analyzer is clean, and the full suite passes with 0 `[E]`. The 48 goldens are
     unchanged (`git status --porcelain test/goldens` is empty). Commit.

### Phase 2: Toggle Sidebar only where it can act

2.1. `sidebar_geometry.dart` is used by the `Sidebar` in `app_shell.dart`.
     `'global.toggleSidebar'` is `sidebarCanShow(MediaQuery.sizeOf(context).width) ? _toggleSidebar : null`.
2.2. `repo_status_view.dart`: `onToggleSidebar` is passed only when
     `sidebarCanShow(MediaQuery.sizeOf(context).width)`.
2.3. `MainFlutterWindow.swift`: in `validateMenuItem`, before the fall-through to `super`:
     `if menuItem.action == #selector(toggleSidebar(_:)) { return enabledActionIds.contains("global.toggleSidebar") }`.
2.4. Tests, each seen to fail before its change:
     * `sidebar_geometry_test.dart`: `sidebarCanShow(760)` is false, and `sidebarCanShow(761)`
       is true;
     * `repo_status_view_test.dart`: with the content at 660 pt (compact) inside a 900 pt window,
       "Toggle sidebar" is present; inside a 700 pt window, it is absent;
     * `app_shell_test.dart`: with the window at 700 pt, `availableActionsProvider` lacks
       `global.toggleSidebar`; at 900 pt it holds it.
2.5. Checks. Commit.

### Phase 3: device gate and records

3.1. `./build_macos.sh --unsigned`, and `--install` only if the maintainer asks.
3.2. Checks, each recorded PASS or FAIL with what was seen, with the maintainer's consent to use
     the screen:

     | Item | Steps | PASS when |
     |---|---|---|
     | Breakpoint | Narrow to 640 pt on the Repository and History pages | The sidebar's former area shows the page: no items, no native material |
     | Toggle | At 900 pt, Toggle sidebar off, then on | It slides away cleanly, and comes back as before |
     | Drag-close | Drag the sidebar's edge past its minimum | As the toggle |
     | Button | The Repository page at 700 pt and at 900 pt (compact at both) | The button shows only at 900 pt |
     | Menu | View → Toggle Sidebar at 700 pt and at 900 pt | Dimmed at 700, available at 900 |
     | ⌘2 at compact width | At 640 pt, press ⌘2 | History opens. A FAIL opens a new record |
     | Wide | 1600 pt | Unchanged |

3.3. Records: this plan's status, `docs/README.md`, and `docs/architecture.md`.
     `dart run scripts/tools/records.dart check` reports 0 findings. Commit.

## Verification

| Check | Command | Pass condition |
|---|---|---|
| Analyzer | `flutter analyze` | No issues found |
| Suite | `flutter test > "$LOG" 2>&1; S=$?` | `S` 0, 0 `[E]` |
| Pixel test | `flutter test test/hidden_sidebar_test.dart` | passes; failed at 0.3 and under the 1.4 mutation |
| Vendored copy | `diff -r` against a fresh `git archive` of the backport commit | no output |
| Lock diff | `git diff pubspec.lock` | macos_ui's source only |
| Build | `./build_macos.sh --unsigned` | exit 0, "(overridden)" in the log |
| Records | `dart run scripts/tools/records.dart check` | 0 findings |

## Acceptance Criteria

* AC1: at 640 pt, and at 900 pt toggled off or drag-closed, no sidebar and no native material
  shows under the content: in `hidden_sidebar_test.dart` and on the device.
* AC2: `third_party/macos_ui` is identical to the backport commit's `lib`, `macos`,
  `pubspec.yaml`, `LICENSE` and `CHANGELOG.md`, and carries `PATCHED.md`. `window.dart` differs
  from tag 2.2.2 by the patch alone.
* AC3: the Toggle Sidebar button and menu item are available only above 760 pt. Pinned by tests
  that failed first; the menu item is also checked on the device.
* AC4: the full suite passes, and the 48 goldens are unchanged.
* AC5: `PATCHED.md` and `docs/architecture.md` state the removal condition: when a macos_ui
  release contains the fix, remove the override and the directory, and move the dependency to
  that release.

## Rollout and Rollback

Rollout is the next build. Rollback is reverting this plan's commits. Removing the override goes
back to pub's 2.2.2, and its ghost. Phase 2 is independent of Phase 1. When upstream releases the
fix, a later change removes `third_party/macos_ui` and the override, moves to that release, and
re-runs `hidden_sidebar_test.dart` against it. Upstream moved slowly on the last fix (nine months
from pull request to merge), so the vendored copy is expected to stay for a while.

## Execution record

*(empty: the plan is proposed)*
