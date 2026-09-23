---
status: "complete"
date: 2026-09-22
associated-madr: "0066-MADR-reveal-a-collapsed-workspace-navigator.md"
verified: 2026-09-22
---

# Implement the navigator reveal rail and the Toggle Navigator command

Associated MADR:
[0066-MADR-reveal-a-collapsed-workspace-navigator.md](0066-MADR-reveal-a-collapsed-workspace-navigator.md)

## Goal

After this plan, a collapsed navigator is visible and reversible at every width: a 28 pt rail
carrying the pane's name stands where the pane was and restores it when clicked, and
**⌥⌘N** / **View ▸ Show Navigator** toggles it from the keyboard and the menu bar with a
checkmark that follows the live state. (This goal said ⇧⌘N when the plan was approved; that
chord was already History's — deviation D1 and MADR Amendment 0066.1.) The preference, the presets and the persisted layout are
unchanged.

## Scope

**In scope**

* `lib/features/common/adaptive_workspace_layout.dart` — the rail, and a `navigatorLabel`.
* `lib/features/common/repository_workspace_scaffold.dart` — pass `navigatorLabel` through.
* The five pages that supply a navigator: `history_view.dart`, `branches_view.dart`,
  `stash_view.dart`, `forge_workspace.dart`, `worktrees_view.dart` — each passes the label it
  already gives `compactNavigation`.
* `lib/features/common/workspace_preferences_binding.dart` — `toggleNavigatorCollapsed`.
* `lib/core/settings/keymap.dart`, `lib/features/app_shell.dart`,
  `lib/features/tabs/tabs_host.dart`, `macos/Runner/MainFlutterWindow.swift`,
  `macos/Runner/help_book.json` — the command, its menu item and its checkmark.
* Tests: `test/workspace_navigator_reveal_test.dart` (new), `test/navigator_label_scan_test.dart`
  (new), and whatever `test/help_book_json_test.dart` requires for the new menu label.

**Out of scope** (each stated in the MADR)

* The inspector (inert) and the task dock: the rail widget is written so they can adopt it, and
  neither is wired here.
* The Minimal preset keeps collapsing the navigator.
* No preference migration: the `ocp-login` tab stays collapsed until revealed.
* The Repository page, which passes no navigator.

## Implementation Steps

Each phase ends with `flutter analyze`, the phase's tests, and one commit
(`git commit --no-edit`). A step that cannot be done as written is a deviation: stop and prompt.

### Phase 0 — Rehearse the failing tests

0.1. `git clone -q <repo> <scratch>/0066-rehearsal` at `HEAD`.
0.2. In the clone only, add `test/workspace_navigator_reveal_test.dart` with the Phase 1 and
     Phase 2 cases and run it.
0.3. **Expected:** the rail cases fail (no rail widget exists, so the finder finds nothing) and
     the ⇧⌘N case fails (no such binding). Record both messages verbatim.
0.4. Nothing is copied back except the test text.

### Phase 1 — The reveal rail

1.1. **`adaptive_workspace_layout.dart`:** add `final String? navigatorLabel;` to
     `AdaptiveWorkspaceLayout`. In the non-compact branch of `_mainFor` (`:400`), when
     `widget.preferences.navigatorCollapsed && navigator != null`, render
     `_NavigatorRevealRail(label: …, onReveal: …)` in place of the `ResizableMasterDetail`'s
     leading pane rather than passing `collapsed: true` with nothing behind it.
     * The rail is 28 pt wide, full height, one `Tappable` (`behavior: HitTestBehavior.opaque`,
       `SystemMouseCursors.click`), wrapped in `Semantics(button: true, label: 'Show <name>')`,
       carrying `CupertinoIcons.chevron_right` above a `RotatedBox(quarterTurns: 1)` of the name
       in `typography.caption1`, with the workspace border colour on its trailing edge.
     * `onReveal` calls `_updatePrefs(widget.preferences.copyWith(navigatorCollapsed: false))`,
       the same path a divider drag uses, so it persists through `onPreferencesChanged`.
     * `Key('workspace-navigator-reveal')` for the tests.
1.2. **`repository_workspace_scaffold.dart`:** add `final String? navigatorLabel;`, pass it down.
     Assert in debug that `navigator == null || navigatorLabel != null`.
1.3. **The five pages** pass `navigatorLabel:` with the string they already use for
     `compactNavigation.navigatorLabel`: 'Commits', 'Branches', 'Stashes', 'Items', 'Worktrees'.
1.4. **`test/workspace_navigator_reveal_test.dart`** (rail half), pumping
     `AdaptiveWorkspaceLayout` directly with a stub navigator and canvas:
     * at 1400 pt with `navigatorCollapsed: true`: the stub navigator is absent, the rail is
       present, its width is 28, and it carries the label;
     * tapping it emits `onPreferencesChanged` with `navigatorCollapsed: false` and the navigator
       returns;
     * at 1400 pt with `navigatorCollapsed: false`: no rail;
     * at 600 pt (compact) with `navigatorCollapsed: true`: no rail — compact keeps its own back
       bar and must not grow a second affordance.
1.5. Verify: `flutter analyze`; the new test; `flutter test test/adaptive_workspace_layout_test.dart
     test/repository_workspace_scaffold_test.dart test/workspace_responsive_test.dart
     test/workspace_golden_test.dart`. Commit.

### Phase 2 — The Toggle Navigator command

2.1. **`workspace_preferences_binding.dart`:** add

     ```dart
     Future<void> toggleNavigatorCollapsed(WidgetRef ref, String repositoryPath) async
     ```

     reading `repositoryUiIdentityProvider` and `repositoryWorkspacePrefsProvider`, saving the
     flipped record with `saveRepositoryWorkspacePrefs`, then invalidating the provider. A null
     identity (disconnected, tests) is a no-op.
2.2. **`keymap.dart`:** `KeymapAction(id: 'global.toggleNavigator', label: 'Toggle Navigator',
     category: KeymapCategory.global, defaultBindings: [KeyBinding.fromKey(LogicalKeyboardKey.keyN,
     meta: true, ~~shift~~ **alt**: true)])`, beside the other view toggles. ⌥⌘N, not ⇧⌘N — see
     deviation D1 and MADR Amendment 0066.1.
2.3. **`app_shell.dart`:** map `'global.toggleNavigator'` to
     `() => toggleNavigatorCollapsed(ref, repoPath)` when connected, null otherwise.
2.4. **`tabs_host.dart`:** add `'global.toggleNavigator'` to `_viewShortcutIds`; handle
     `case 'toggleNavigator'` in `_handleMenuCall`; sync `setNavigatorChecked` from the active
     container's prefs (checked = **not** collapsed) wherever the other four are synced.
2.5. **`MainFlutterWindow.swift`:** `showNavigatorItem` via `addToggleItem(to: viewMenu, title:
     "Show Navigator", key: "n", action: #selector(toggleNavigator(_:)))` after the File View
     item; the `@objc` method invokes `toggleNavigator` on the menu channel; `apply(
     showNavigatorItem, "global.toggleNavigator")` in the shortcut sync; a
     `setNavigatorChecked` case beside the others.
2.6. **`help_book.json`:** add "Show Navigator" to the View-menu inventory string and one
     sentence to the workspace-chrome topic: what the rail is and that ~~⇧⌘N~~ ⌥⌘N does the same.
     `test/help_book_json_test.dart` cross-checks the label against the Swift installer.
2.7. **`workspace_navigator_reveal_test.dart`** (command half), on a connected `AppShell` as
     `output_view_placement_test.dart` does: ~~⇧⌘N~~ ⌥⌘N hides the navigator on History and shows
     it again, asserting the rendered pane and the rail — not the flag. A second case pins that
     ⇧⌘N still reaches History's "Branch from selected commit" (D1).
2.8. Verify: `flutter analyze`; the new test; `flutter test test/help_book_json_test.dart
     test/chrome_correctness_test.dart test/keymap_test.dart test/tabs_host_test.dart` — all four
     exist. Commit.

### Phase 3 — The scan test, the suite and the device

3.1. **`test/navigator_label_scan_test.dart`:** scan `lib/features/**` for
     `RepositoryWorkspaceScaffold(` calls that pass `navigator:` and require `navigatorLabel:` in
     the same argument list, so a new page cannot ship an unnamed, unreachable pane. Seen to fail
     by deleting one page's label in a scratch copy.
3.2. `flutter analyze`; full suite to a log; `[E]` count 0.
3.3. `./build_macos.sh --unsigned`; on the `ocp-login` tab: History shows the rail with
     "Commits"; clicking it restores the commit list; ~~⇧⌘N~~ ⌥⌘N hides and shows it; View ▸ Show
     Navigator carries the right checkmark. Record what was seen.
3.4. Update both records' status, `docs/README.md`, and the execution record.
     `dart run tool/records.dart check` prints `0 finding(s)`. Commit.

## Verification

| Check | Command | Pass condition |
|---|---|---|
| Static analysis | `flutter analyze` | `No issues found!` |
| Rail + command | `flutter test test/workspace_navigator_reveal_test.dart` | all pass |
| Negative | Phase 0 in the scratch clone | both halves fail, messages recorded |
| Scan | `flutter test test/navigator_label_scan_test.dart` | passes; fails with a label removed |
| Layout regressions | `flutter test test/adaptive_workspace_layout_test.dart test/workspace_responsive_test.dart test/workspace_golden_test.dart` | unchanged, goldens not regenerated |
| Menu/help | `flutter test test/help_book_json_test.dart` | passes with the new label |
| Full suite | `flutter test > "$LOG" 2>&1` | exit 0, `grep -c '\[E\]'` prints 0 |
| Device | Phase 3.3 | all four observations |
| Records | `dart run tool/records.dart check` | `0 finding(s)` |

## Acceptance Criteria

* AC1 — The rail tests fail on the current tree (Phase 0) and pass after Phase 1.
* AC2 — A collapsed navigator shows a 28 pt named rail at standard and wide widths, and none at
  compact width.
* AC3 — Clicking the rail persists `navigatorCollapsed: false` through `onPreferencesChanged`.
* AC4 — ~~⇧⌘N~~ ⌥⌘N (D1) and View ▸ Show Navigator both toggle it, and the menu checkmark
  follows.
* AC5 — The scan test rejects a `navigator:` without a `navigatorLabel:`.
* AC6 — The 48 workspace goldens are unchanged and not regenerated.
* AC7 — Full suite green with 0 `[E]`; records check clean; the device checks recorded.

## Rollout and Rollback

Rollout is the next `./build_macos.sh --unsigned --install`. No preference migrates, so a
rollback needs no data work: `git revert` of the three phase commits, newest first, restores the
previous behaviour, and any repository whose navigator was revealed simply stays revealed
(`navigatorCollapsed: false` is the default).

## Execution record

* **Phase 0 (2026-09-22).** Scratch clone of `82dd552`; `workspace_navigator_reveal_test.dart`
  copied in, nothing else changed.
  * **First run proved too little.** It failed to compile — `Error: No named parameter with the
    name 'navigatorLabel'` — which shows the API is missing, not that the behaviour is. The
    rehearsal copy's three `navigatorLabel:` arguments were stripped (a scratch script, asserting
    the count first: it caught a miscount of 2 against the real 3 and refused to edit) so the
    test compiles against the unmodified tree.
  * **Second run, on behaviour:** `+2 -3`.
    * `a collapsed navigator leaves a named rail, not a void` — `Expected: exactly one matching
      candidate` / `Actual: Found 0 widgets with key [<'workspace-navigator-reveal'>]` /
      `the collapsed pane leaves something to click`.
    * `tapping the rail restores the pane and persists it` — same finder, nothing to tap.
    * `⇧⌘N hides the navigator and shows it again` — `Found 0 widgets with key
      [<'workspace-navigator-reveal'>]` / `⇧⌘N collapsed the navigator, and the rail says so`.
    * The two that passed are the negative cases, which must pass on both trees: an expanded
      navigator has no rail, and compact grows none.
* **Phase 1 (2026-09-22).** As written: `kWorkspaceNavigatorRevealKey`,
  `kWorkspaceNavigatorRailWidth = 28` and `_NavigatorRevealRail` in
  `adaptive_workspace_layout.dart`; the non-compact branch returns the rail beside the canvas
  while `navigatorCollapsed`, with `onReveal` writing through `_updatePrefs`; `navigatorLabel`
  added to the layout and the scaffold, with the debug assert; the five pages pass the label
  they already give `compactNavigation`.
  * **Deviation, resolved: three test fixtures had to change too.** The assert fired in
    `workspace_accessibility_test.dart:38`, `workspace_responsive_test.dart:42` and
    `workspace_golden_test.dart:125` — each builds a scaffold with a navigator and, before this,
    no name for it (`+8 -54`, every failure the same assert). They now pass
    `navigatorLabel: 'Changes'`, which is what the pane they stub represents. No production
    behaviour changed, and the assert is doing exactly what it was added for; the three files
    are added to this plan's scope.
  * `flutter analyze`: `No issues found! (ran in 6.1s)`; `dart format --set-exit-if-changed` on
    the eight touched files: clean. `flutter test test/adaptive_workspace_layout_test.dart
    test/repository_workspace_scaffold_test.dart test/workspace_responsive_test.dart
    test/workspace_golden_test.dart test/workspace_accessibility_test.dart`: `00:02 +71: All
    tests passed!`, 0 `[E]` — **the 48 goldens pass unchanged and were not regenerated** (AC6).
  * `flutter test test/workspace_navigator_reveal_test.dart`: `+4 -1` — all four rail cases
    pass; the remaining failure is the command case, which is Phase 2.
* **D1 (2026-09-22, deviation, Phase 2): ⇧⌘N is already taken, and the MADR said it was free.**
  * **Evidence.** `lib/core/settings/keymap.dart:527-532` binds ⇧⌘N to `history.branchFrom`
    ("Branch from selected commit") and predates this work — the file was untouched when the
    collision was found. A sweep of every default binding (a scratch script parsing
    `KeymapAction` blocks) printed the whole table: the existing shared chords are `⌘F`, `⌘N`,
    `⌥⌘A` and `⌥⌘R`, each between panels that are never active together — unlike a **global**
    command, which would be live on History alongside `history.branchFrom`, with the native
    menu's key equivalent beating Flutter's handler.
  * **Resolutions offered:** ⌥⌘N (free, and the modifier the app's other view toggles use);
    ship unbound; or move `history.branchFrom`.
  * **Decision (maintainer, 2026-09-22): ⌥⌘N.** Recorded as MADR Amendment 0066.1. Step 2.2
    above is struck through and corrected; `addToggleItem` gains a `modifiers` parameter
    (default ⇧⌘, so no other item changes) and the navigator item passes `[.command, .option]`.
  * **A second, smaller deviation, resolved in passing.** A first attempt at the help-book edit
    used a script that fell back to rewriting the whole document, which reflowed unrelated
    `shortcuts` arrays (+317/−64, then +71/−342 when "fixed"). `macos/Runner/help_book.json`
    was restored with `git show HEAD:… > …` — never `git checkout` — and the three edits
    re-applied as anchored text splices, leaving a 3-line diff. The lesson is in the record
    because the first script silently passed its own assertions.
* **Phase 2 (2026-09-22).** `toggleNavigatorCollapsed` in `workspace_preferences_binding.dart`
  (identity → record → flipped save → invalidate; a session with no identity is a no-op);
  `global.toggleNavigator` in `keymap.dart` bound ⌥⌘N; the handler in `app_shell.dart`;
  `_viewShortcutIds`, the `toggleNavigator` menu case and a repo-keyed `_navigatorSub` that
  pushes `setNavigatorChecked` in `tabs_host.dart`; five mirrored sites in
  `MainFlutterWindow.swift` (the stored item, the checkmark case, the installation with
  `modifiers: [.command, .option]`, the key-equivalent sync, the action); the help book's
  inventory, workspace sentence and catalog entry.
  * **A third small deviation:** the shell test could not exercise the command, because
    `toggleNavigatorCollapsed` needs a repository identity and a widget test resolves none, so
    the toggle was correctly doing nothing. The test now overrides
    `repositoryUiIdentityProvider('/srv/repo')` with a real `RepositoryUiIdentity.ssh`, which
    makes it exercise the true save → invalidate → reload path rather than a stub. No
    production change; the no-op for an identity-less session is deliberate and stays.
  * **A guard for D1 was added** to the test file: ⇧⌘N on History must **not** reveal the rail,
    so a future rebind cannot quietly take History's chord.
  * `flutter analyze`: `No issues found! (ran in 4.6s)`.
    `flutter test test/workspace_navigator_reveal_test.dart`: `00:01 +6: All tests passed!`.
    `flutter test test/help_book_json_test.dart test/chrome_correctness_test.dart
    test/keymap_test.dart test/tabs_host_test.dart`: `00:02 +51: All tests passed!`, 0 `[E]`.
* **Phase 3, step 3.1 (2026-09-22).** `test/navigator_label_scan_test.dart` walks `lib/` for
  `RepositoryWorkspaceScaffold(` calls, matching each call's parentheses so nested calls and
  trailing commas are handled, and requires `navigatorLabel:` wherever `navigator:` is passed.
  * **The first version was wrong, and its own negative test caught it.** It asked whether the
    call text *contained* `navigatorLabel:`, which History satisfies through its nested
    `compactNavigation: CompactWorkspaceNavigation(navigatorLabel: 'Commits')` — so with the
    scaffold's own label deleted the scan still passed (`exit=0`, "All tests passed"). It now
    collects the call's **top-level** argument names by tracking bracket depth, and ignores
    anything a nested call passes.
  * **Seen to fail:** scratch clone with the fixed files, History's scaffold `navigatorLabel:`
    removed → `00:00 +0 -1: Some tests failed.`; restored → passes. The test also asserts it
    scanned at least one call, so a pattern change cannot leave it silently vacuous.
  * A second scratch script found the ambiguity that made this necessary: History carries two
    `navigatorLabel:` lines (the scaffold's and `compactNavigation`'s), and an anchored edit
    asserting a single match refused to run until the anchor named the right one.
* **Phase 3, step 3.2 (2026-09-22).** `flutter analyze`: `No issues found! (ran in 6.1s)`.
  Full suite: `02:54 +4326 ~3: All tests passed!`, `[E]` count 0 — `+7` over `82dd552` (six
  reveal cases and the scan test). The 48 goldens are among them, unchanged (AC6).
* **Phase 3, step 3.3 (2026-09-22): built, and the maintainer's to confirm.**
  `./build_macos.sh --unsigned` exited 0. The built binary carries `showNavigatorItem`, the
  `toggleNavigator:` selector and `global.toggleNavigator`, and the shipped `help_book.json`
  carries "Show Navigator" and `global.toggleNavigator`, so the Swift and help changes are in
  the bundle. (The menu *titles* are absent from the binary's string table because Swift packs
  literals of ≤ 15 UTF-8 bytes inline — "Show Navigator" and "Show File View" are both 14 bytes,
  while the 19-byte "Show Dashboard View" does appear. Not evidence of a missing item.)
  * **Not executor-run.** The checks need the maintainer's own window and keyboard on the
    `ocp-login` tab, and the 0064 gate's amended procedure already puts keyboard-sequence checks
    with the maintainer. Until they are recorded here, **AC4 and the device half of AC7 are
    open** and this plan stays `in-progress`.
  * What to look for: History on that tab shows a 28 pt rail labelled "Commits"; clicking it
    restores the commit list; ⌥⌘N hides and shows it; View ▸ Show Navigator carries a checkmark
    that follows.
* **D2 (2026-09-22, deviation, after Phase 2 shipped): ⌥⌘N did nothing on the device.**
  * **Reported** by the maintainer on the installed build. The build was confirmed to contain
    the change (`global.toggleNavigator` in the binary, `workspace-navigator-reveal` and
    `toggleNavigatorCollapsed` in `App.framework`), so it was not a stale install.
  * **Cause: the wrong provider container.** The native ⌥⌘N key equivalent is consumed by the
    menu item, so the command arrives through `TabsHost._handleMenuCall`, which runs in the
    **root** container while each tab's pages live in their own. Every sibling case reads
    through `c`, the active tab's container; the `toggleNavigator` case passed the host's own
    `ref` (`tabs_host.dart:361` as shipped in `dd38c36`), so the preference was written and
    invalidated where no page was watching. The Flutter-side ⌥⌘N path in `AppShell` was
    correct, which is why the widget test — one container, no tabs — passed.
  * **Fix.** `toggleNavigatorCollapsed` now takes a `ProviderContainer` instead of a
    `WidgetRef`: `TabsHost` passes the active tab's `c`, `AppShell` passes
    `ProviderScope.containerOf(context, listen: false)`. One implementation, and the caller
    states which container it means.
  * **Regression test** in `test/tabs_host_test.dart`: a connected tab with a real identity,
    `toggleNavigator` sent over the `magicgit/menu` channel, and the assertion that **that
    tab's** record flipped. **Seen to fail** with the menu routed through the root container
    again: `Expected: <true>` / `Actual: <false>` / "the menu item toggled the pane in the tab
    the user is looking at, not in the host's root container". It needed its own container
    factory — the file's shared one pins every tab disconnected, and overriding
    `connectionProvider` twice throws.
  * **Files added to scope:** `test/tabs_host_test.dart`.
  * `flutter analyze`: `No issues found! (ran in 5.5s)` — a first run reported an unused import
    and an out-of-order one in the test, both fixed before the commit.
    `flutter test test/tabs_host_test.dart test/workspace_navigator_reveal_test.dart
    test/navigator_label_scan_test.dart`: `00:02 +19: All tests passed!`, 0 `[E]`.
    Full suite: `02:52 +4327 ~3: All tests passed!`, 0 `[E]`.
  * **Confirmed on the device (maintainer, 2026-09-22): step 3.3 passes.** The rail appears for
    a collapsed navigator and restores the pane when clicked, ⌥⌘N toggles it, and the View-menu
    checkmark follows. The installed bundle's `App.framework` is stamped 19:54, two minutes
    after this fix's commit (`0e58304`, 19:52), so the build under test carries it. **AC4 met**,
    and with it every acceptance criterion; this plan is `complete`.
