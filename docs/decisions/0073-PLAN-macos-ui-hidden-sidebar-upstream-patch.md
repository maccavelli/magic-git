---
status: "proposed"
date: 2026-09-26
associated-madr: "0073-MADR-hidden-sidebar-slides-off-screen-in-a-patched-macos-ui.md"
verified: 2026-09-26
---

# Implement the macos_ui patch: a hidden start sidebar slides off-screen and out of input

Associated MADR:
[0073-MADR-hidden-sidebar-slides-off-screen-in-a-patched-macos-ui.md](0073-MADR-hidden-sidebar-slides-off-screen-in-a-patched-macos-ui.md)

Companion plan (Magic Git side): `0073-PLAN-vendor-patched-macos-ui-and-toggle-rule.md`.

## Goal

A branch of the fork, off upstream `dev`, on which a hidden start sidebar is off-screen, not
hit-testable, not focusable and absent from the live semantics tree, by each of the three hiding
routes, and its native material follows it. It must satisfy the project's contribution rules
and its CI, proven locally, and be ready for the maintainer of Magic Git to review before anything
is pushed.

## Scope

**Where:** `~/gitrepos/macos_ui`. Remotes: `upstream` = `https://github.com/macosui/macos_ui.git`
(push URL set to `NO_PUSH_to_upstream`), and `origin` = `https://github.com/<maintainer>/macos_ui.git`
(the fork, created 2026-09-26, nothing pushed).

**Files the pull request changes (and only these):**
* `lib/src/layout/window.dart`
* `test/layout/window_test.dart`
* `CHANGELOG.md` (a new `[2.2.4]` section)
* `pubspec.yaml` (`version: 2.2.4`)

That is the same file set as #588, the last fix merged to this file.

**Out of scope:**
* the end sidebar, which is already correct;
* any public API, and any `Sidebar` parameter;
* #588's background change, which is kept as it is;
* the 10 pre-existing theme test failures, the 2 unformatted files already on `dev`, and the lock
  files;
* pushing, filing the issue, and opening the pull request. Each needs the Magic Git maintainer's
  explicit request in that turn.

## Facts this plan is built on (verified 2026-09-26)

Every line reference was checked against the file by a script (36 of 36 anchors hold).

| Fact | Evidence |
|---|---|
| `upstream/dev` = `dec19cf` (2026-08-22), version 2.2.3 | `git log`, `pubspec.yaml:3` |
| The start sidebar's `AnimatedPositioned` has `width` but no `left` | `window.dart:255-260` (`dev`) |
| The content is at `left: visibleSidebarWidth` | `window.dart:393` |
| The resizer is at `left: visibleSidebarWidth - 4` | `window.dart:421` |
| Drag-close is `_showSidebar = newWidth >= closeBelow` | `window.dart:447` |
| The end sidebar is at `left: width - visibleEndSidebarWidth` | `window.dart:482` |
| `canShowSidebar = _showSidebar && !isAtBreakpoint && sidebar != null` | `window.dart:231-232` |
| The slide duration is 0 until a toggle sets it to 300 | `window.dart:97`, `:606` |
| `TransparentMacOSSidebar` is given only `state:` | `window.dart:328` |
| The relay's `onResize()` exists for "position … change without triggering a rebuild" | macos_window_utils `…_resize_event_relay.dart:29-34`, identical in 1.9.0 and 1.9.1 |
| `find.semantics.byLabel` searches the live tree from the semantics owner's root | flutter_test 3.47.2 `finders.dart:89`, `:724`, `:1261-1272` |
| Each merged PR bumps the version and adds its own CHANGELOG section | #579 → 2.2.1, #585 → 2.2.2, #588 → 2.2.3, read from their merge commits |
| CI runs on `pull_request`, on `ubuntu-latest`; fork PRs have had no runs since 2025-10 | `.github/workflows/*.yml`; the Actions API |
| CI's "Format code" step never fails: plain `dart format .` exits 0 | `flutter_analysis.yml:24-31` |
| DCM runs in CI with only `GITHUB_TOKEN` | `flutter_analysis.yml:38-44` |
| The example app has a start and an end sidebar; `windowBreakpoint` defaults to 556 | `example/lib/main.dart:75-76`, `:266`; `sidebar.dart:22` |

**Measured baseline** on `dev`, with the `flutter` on `PATH` (3.47.2 stable, the version Magic Git
pins in `build_macos.sh:46`):
* `flutter analyze --fatal-infos .`: No issues found.
* `flutter test`: `+188 -10`. The 10 failures are `test/theme/{help_button,icon_button,icon,popup_button,pulldown_button}_theme_test.dart`,
  "lerps from dark to light" and "lerps from light to dark" in each. `window_test.dart`: `+16`,
  all pass.
* `dart format --set-exit-if-changed .`: 2 files would change (`lib/src/layout/sidebar/sidebar_items.dart`,
  `test/buttons/pulldown_button_test.dart`), both already on `dev`.
* `flutter pub get --enforce-lockfile` fails (the lock file predates 3.47.2's pinned packages).
  `flutter analyze` then runs `pub get` itself, and rewrites `pubspec.lock`, `example/pubspec.lock`
  and `analysis_options.yaml`.

**Measured with a prototype** of the change in scratch worktrees (never committed), on `dev` and
on tag 2.2.2: every hidden route gives a rect ending at x = 0, not hit-testable, not focusable,
absent from the live tree. The shown control is unchanged. `window_test.dart` passes (+16). The
full suite fails exactly the baseline's 10 (compared as sets). The analyzer is clean.

## Implementation Steps

Rules for every phase:
* Checks are run with output redirected to a file and judged on the exit status.
* Commits use `git commit --no-edit`, so the global hook writes a conventional commit, which the
  project requires. **Stage files by name, only from the file set in Scope.** Never `git add -A`:
  the tools rewrite the lock files and `analysis_options.yaml`.
* A step that cannot be done as written is a deviation: stop and prompt.

### Phase 0: branch and baseline

0.1. The clone's checkout of `dev` holds three files the tools rewrote during the review
     (`analysis_options.yaml`, `pubspec.lock`, `example/pubspec.lock`), and their diff is saved
     in the session scratchpad. With the maintainer's approval, restore them
     (`git restore analysis_options.yaml pubspec.lock example/pubspec.lock`). Then
     `git status --porcelain` is empty.
0.2. Confirm the hook: `git rev-parse --path-format=absolute --git-path hooks` prints the global
     hooks directory.
0.3. `git fetch upstream && git switch -c fix/hidden-sidebar-off-screen upstream/dev`. If `dev`
     has moved past `dec19cf`, record the new commits and re-check the Facts table before going
     on.
0.4. Baseline, recorded: `flutter --version` (3.47.2), `flutter analyze --fatal-infos .`,
     `flutter test` (expect `-10`, with the names above), `dart format --output=none
     --set-exit-if-changed lib/src/layout/window.dart test/layout/window_test.dart` (expect 0).
0.5. DCM: with the maintainer's approval, install it (`brew tap CQLabs/dcm && brew install dcm`),
     then run `dcm analyze .` on the unmodified branch and record the result. If it will not run
     without a licence, record that; the pull request then states it, and CI is its first run.

### Phase 1: the failing tests

In `test/layout/window_test.dart`, inside `group('MacosWindow')`, a new group, "a hidden start
sidebar is off-screen and out of input", in the file's own style (trailing commas, and a closing
`await tester.pump(Duration.zero)` in each test):

1.1. Fixture: `MacosWindow(disableWallpaperTinting: true, sidebar: …, child: ContentArea(…))`.
     The content paints nothing, which is the exposed case; the file's existing tests all use an
     opaque `MacosScaffold`. The sidebar has `minWidth: 100`, `startWidth: 150`, `maxWidth: 300`
     and `windowBreakpoint: 700`. Its builder returns `Focus(focusNode: probeFocus,
     child: Semantics(label: 'sidebar probe', child: ColoredBox(key: probeKey, …)))`. The probe
     must be a `ColoredBox`: a childless `SizedBox` never appears in a hit-test path, so it cannot
     answer the question (measured: `hitTestable` was false even when the sidebar was shown).
1.2. Three routes, with the window at 1000 × 600 unless stated:
     * **breakpoint:** the window at 600 × 600;
     * **toggle:** `MacosWindowScope.of(context).toggleSidebar()`, with the context captured in
       `ContentArea`'s builder;
     * **drag-close:** `tester.drag(find.byType(AnimatedPositioned).at(3), const Offset(-500, 0))`,
       the resizer as the existing tests find it.
     After `pumpAndSettle()`, each asserts:
     * `tester.getRect(find.byKey(probeKey)).right <= 0`;
     * `find.byKey(probeKey).hitTestable()` finds nothing;
     * `probeFocus.canRequestFocus == false`;
     * `find.semantics.byLabel('sidebar probe')` finds nothing, under `tester.ensureSemantics()`.
       Not `find.bySemanticsLabel`: after an exclusion changes, it still reports the stale node
       (measured on the toggle and drag routes).
1.3. Controls:
     * a shown sidebar has `left == 0`, `width == 150`, is hit-testable, can take focus, and is
       found by `find.semantics.byLabel`;
     * toggling off and on again restores all four;
     * the end sidebar's behaviour, as the existing tests pin it, is untouched.
1.4. Wiring: the start sidebar's `AnimatedPositioned` has a non-null `onEnd`, and on the macOS
     path the `TransparentMacOSSidebar` has a non-null `resizeEventRelay`. The native effect is a
     device check (Phase 3); these assertions pin that the relay is connected.
1.5. **Seen to fail** on the unmodified branch. Expected, from the review's measurement: every
     hidden-route assertion fails (`right` is 150 or 100, not ≤ 0, and the probe is hit-testable,
     focusable and in semantics). 1.4 fails because both are null. The shown controls pass. Record
     each failure message. A harness failure is fixed first and does not count.

### Phase 2: the change

2.1. In `_MacosWindowState`, next to `_sidebarSlideDuration`:
     `final _sidebarVisualEffectRelay = VisualEffectSubviewContainerResizeEventRelay(disableUpdateOnBuild: false);`
     with the import
     `package:macos_window_utils/widgets/visual_effect_subview_container/visual_effect_subview_container_resize_event_relay.dart`.
     It is in macos_window_utils 1.9.0, the floor of the `^1.9.0` constraint.
2.2. The start sidebar's `AnimatedPositioned` gets `left: visibleSidebarWidth - _sidebarWidth`
     and `onEnd: _sidebarVisualEffectRelay.onResize`.
2.3. Its child is wrapped as `IgnorePointer(ignoring: !canShowSidebar, child:
     ExcludeFocus(excluding: !canShowSidebar, child: ExcludeSemantics(excluding:
     !canShowSidebar, child: AnimatedContainer(…))))`.
2.4. `TransparentMacOSSidebar` gets `resizeEventRelay: _sidebarVisualEffectRelay`.
2.5. One comment at the change says why:
     * the end sidebar already slides off;
     * content that paints nothing leaves a sidebar at x = 0 visible and reachable;
     * the relay moves the native view, which a slide does not rebuild.
2.6. `dart format` on the two files. Phase 1 passes. `window_test.dart` passes as a whole (16
     existing tests plus the new ones).
2.7. **Mutations**, in a scratch worktree off the branch (`git worktree add --detach`), each run
     against the new tests and each seen to fail a named test:
     1. `left` removed;
     2. `IgnorePointer` removed;
     3. `ExcludeFocus` removed;
     4. `ExcludeSemantics` removed;
     5. `onEnd` removed;
     6. `resizeEventRelay` removed.
     The worktree is removed afterwards.
2.8. The full suite fails exactly the baseline's 10, compared as sets, and
     `flutter analyze --fatal-infos .` is clean. Commit `lib/src/layout/window.dart` and
     `test/layout/window_test.dart`.

### Phase 3: the native material, on a device

3.1. `cd example && flutter run -d macos --release`. The example depends on the package by path,
     so it runs the branch. Record the build's exit and the SDK.
3.2. With the maintainer's consent to use the screen, for each route, capture the window after
     the slide:
     * narrow the window below 556 pt;
     * the toolbar's sidebar toggle;
     * drag the edge past the minimum.
     The capture shows the former sidebar area with no Flutter items and no translucent native
     material. The end sidebar's toggle is the control.
3.3. The same captures on unpatched `dev` (the example run from a scratch worktree of `dev`), for
     the before/after of the pull request.
3.4. If the material stays at x = 0 despite the relay, stop: that is a deviation, with the
     captures as evidence, and the design goes back to the maintainer. Record the findings (not
     the images) here.

### Phase 4: conformance, the issue draft and the pull request draft

4.1. `pubspec.yaml`: `version: 2.2.4`. `CHANGELOG.md`: a new top section in the house format:
     ```
     ## [2.2.4]
     ### 🛠 Fixed 🛠
     - A hidden start `Sidebar` (below `windowBreakpoint`, toggled off, or drag-closed) now slides off-screen like the end sidebar, and takes no pointer, focus or semantics while hidden. Previously it stayed at the window's leading edge beneath the content, visible wherever the content paints no background.
     ```
4.2. Re-run everything in 0.4 on the branch, and DCM if 0.5 found it runnable. The suite fails
     exactly the baseline's 10. Commit `pubspec.yaml` and `CHANGELOG.md`.
4.3. Draft, here, following #587/#588's precedent:
     * **an issue:** the defect, a minimal reproduction (the Phase 1 fixture), the three routes,
       and the before captures;
     * **a pull request** to `dev` in `.github/PULL_REQUEST_TEMPLATE.md`'s form: what and why,
       before/after captures, the tests, the checklist ticked truthfully, the SDK used, and the 10
       pre-existing theme failures stated as unrelated.
4.4. Stop for the review by the maintainer of Magic Git. Filing the issue, pushing
     `fix/hidden-sidebar-off-screen` to `origin`, and opening the pull request happen only on their
     explicit request, each in that turn.

## Verification

| Check | Command | Pass condition |
|---|---|---|
| Analyzer | `flutter analyze --fatal-infos . > "$LOG" 2>&1; S=$?` | `S` 0, "No issues found" |
| Format (touched files) | `dart format --output=none --set-exit-if-changed lib/src/layout/window.dart test/layout/window_test.dart` | exit 0 |
| Window tests | `flutter test test/layout/window_test.dart` | all pass |
| Suite | `flutter test > "$LOG" 2>&1` | fails exactly the 10 baseline tests, as a set |
| Seen to fail | Phase 1.5 on the unmodified branch | each new hidden-route and wiring test fails, messages recorded |
| Mutations | Phase 2.7 | 6 of 6 fail a named test |
| Device | Phase 3 | no ghost and no native material after any route |
| DCM | `dcm analyze .` | clean, or recorded as not runnable here |
| Staged files | `git diff --cached --name-only` before each commit | only files from the Scope list |

## Acceptance Criteria

* AC1: after each of the three routes, the start sidebar is off-screen, not hit-testable, not
  focusable, and absent from the live semantics tree. Pinned by tests that failed on the
  unmodified branch.
* AC2: a shown sidebar, the toggle back on, the end sidebar and resizing behave as before; the 16
  existing window tests pass unchanged.
* AC3: the native material follows the sidebar on a device, by each route.
* AC4: the analyzer is clean, the touched files are formatted, and the suite fails only the 10
  pre-existing theme tests. DCM is clean, or its absence is stated.
* AC5: version 2.2.4 with its own CHANGELOG section, conventional commits, only the four Scope
  files changed, and no public API change.
* AC6: the issue and pull request drafts are reviewed by the maintainer of Magic Git before
  anything leaves this Mac.

## Rollout and Rollback

Nothing leaves this Mac until the maintainer asks. The branch can be deleted with no effect
upstream. If upstream's review changes the design, the companion plan's backport follows the
merged version, and this record notes the difference.

## Execution record

*(empty: the plan is proposed)*
