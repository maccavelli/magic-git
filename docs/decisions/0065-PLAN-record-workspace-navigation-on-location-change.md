---
status: "in-progress"
date: 2026-09-22
associated-madr: "0065-MADR-record-workspace-navigation-on-location-change.md"
verified: 2026-09-22
---

# Implement change-keyed, active-only workspace navigation recording

Associated MADR:
[0065-MADR-record-workspace-navigation-on-location-change.md](0065-MADR-record-workspace-navigation-on-location-change.md)

## Goal

Remove the per-frame rebuild cycle found as deviation D5 of
[0064-PLAN](0064-PLAN-workspace-reachability-feedback-and-log-fidelity.md): after this plan, a
panel records a navigation entry only when the location its landed data resolves to **changes**,
only while it is the **active** page, and a navigation write rebuilds the context bar and nothing
else. Back, Forward, palette reveals and the unavailable-location protocol from 0009 H3 behave as
they do today.

## Scope

**In scope**

* `lib/features/common/workspace_location_recorder.dart` — new; the `WorkspaceLocationRecorder`
  mixin.
* `lib/features/common/workspace_navigation.dart` — retire `_staleEcho` and its branches in
  `visit` and `reveal`.
* `lib/features/app_shell.dart` — `_pages` watches `locations.isEmpty` only.
* `lib/features/history/history_view.dart`, `lib/features/branches/branches_view.dart`,
  `lib/features/stash/stash_view.dart`, `lib/features/worktrees/worktrees_view.dart` — mix in the
  recorder; replace the in-callback `visit` with one `recordWorkspaceLocation` call.
* `test/workspace_navigation_test.dart`, `test/history_actions_test.dart`,
  `test/branches_view_test.dart`, `test/stash_view_test.dart`, `test/worktrees_view_test.dart` —
  the regression tests in the MADR's Confirmation.
* `docs/README.md` status rows; this plan's execution record; the MADR's status.

**Out of scope** (each named in the MADR's More Information)

* The forge panels: they already record from their selection handlers.
* The shell's `IndexedStack` rebuilding every visited page whenever the shell rebuilds for any
  other reason.
* The synthetic-Esc-on-pulldown observation; it needs a real-keyboard check by the maintainer.
* Any change to what a location contains or to the adapters that apply a restored one.

## Implementation Steps

Each phase ends with `flutter analyze`, the tests named in that phase, and one commit
(`git commit --no-edit`; the hook writes the message). A step that cannot be done as written is a
deviation: stop and prompt, per the global rules.

### Phase 0 — Rehearse the regression test against the unfixed tree

The tests must be seen to fail before the fix exists, in a scratch clone so the working tree is
never dirtied for a diagnostic.

0.1. `git clone -q <repo> <scratch>/0065-rehearsal`, at `HEAD`.
0.2. In the clone only, add the History regression test from step 2.2 (both cases) to
     `test/history_actions_test.dart` and run
     `flutter test test/history_actions_test.dart --plain-name "records a location once"`.
0.3. **Expected:** the "rebuild does not re-record" case fails with `locations` longer than two
     (History re-records its commit on the frame after the foreign visit), and the
     `isActive: false` case fails with one entry where none is expected. Record both failure
     messages verbatim in the execution record. If either case passes on the unfixed code, the
     test does not measure the defect — stop and rewrite it before Phase 1.
0.4. Nothing from the clone is copied back except the test text, in Phase 2.

### Phase 1 — Recorder, notifier, shell

1.1. **Create `lib/features/common/workspace_location_recorder.dart`:**

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'workspace_focus.dart';
import 'workspace_navigation.dart';

/// Records a panel's current location in the session's navigation history:
/// once per change, and only while the panel is the active page.
///
/// Panels call [recordWorkspaceLocation] from `build` with the location their
/// landed data resolves to, because that is where the comparison base, range
/// end or path filter a location carries is known. The call is idempotent — an
/// unchanged location schedules nothing — so a rebuild is not a visit, and two
/// mounted panels holding selections can no longer alternate entries one
/// frame at a time (0065-MADR).
mixin WorkspaceLocationRecorder<T extends ConsumerStatefulWidget>
    on ConsumerState<T> {
  WorkspaceFocus? _recordedLocation;

  /// [location] is null when nothing is selected; [active] is the panel's
  /// `widget.isActive`. Hidden panels record nothing and forget what they last
  /// recorded, so becoming the active page with a selection records it once.
  /// A deselection also forgets, so re-selecting the same object records again.
  void recordWorkspaceLocation(
    WorkspaceFocus? location, {
    required bool active,
  }) {
    if (!active || location == null) {
      _recordedLocation = null;
      return;
    }
    if (location == _recordedLocation) return;
    // Set before scheduling: two builds in one frame must not double-record.
    _recordedLocation = location;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref
          .read(
            workspaceNavigationProvider(
              WorkspaceSessionKey(
                location.repositoryPath,
                location.sessionEpoch,
              ),
            ).notifier,
          )
          .visit(location);
    });
  }
}
```

1.2. **`lib/features/common/workspace_navigation.dart`:** remove the `_staleEcho` field and its
     doc comment (`:55-62`), the guard block at the top of `visit` (`:72-77`), and the
     `_staleEcho` assignment in `reveal` (`:100`). `reveal` becomes: `visit(location); if
     (state.current == location) state = state.copyWith(pending: location, clearUnavailable:
     true);`. `_restore` no longer assigns `_staleEcho` (`:111`). The `markUnavailable` comment
     that mentions the echo (`:134-136`) is rewritten to say only that `unavailable` is set and
     `pending` cleared.
1.3. **`lib/features/app_shell.dart:1157`:**
     `final navigationEmpty = ref.watch(workspaceNavigationProvider(key).select((s) =>
     s.locations.isEmpty));` and use `navigationEmpty` at `:1158`. No other use of `navigation`
     exists in `_pages`.
1.4. **`test/workspace_navigation_test.dart`:** delete the test "a restore ignores the stale echo
     but not a new visit" (`:107`). Add "reveal of the current location leaves the stack
     unchanged and sets pending" if not already covered by "reveal sets pending; visit does not"
     (`:88`) — read that test first; add only what it does not assert.
1.5. Verify: `flutter analyze`; `flutter test test/workspace_navigation_test.dart
     test/app_shell_test.dart test/app_shell_undo_test.dart`. Commit.

### Phase 2 — The four panels and their regression tests

For each panel, the existing post-frame callback keeps its supplement `publish` and loses its
`visit`; the location expression it built inline moves, unchanged, into a
`recordWorkspaceLocation(...)` call made **in `build`, after the callback is registered**.

2.1. **History (`lib/features/history/history_view.dart`).** `class _HistoryViewState` gains
     `with WorkspaceLocationRecorder`. Inside the `if (supplementKey != null && selectedHash !=
     null)` block (`:1531`), delete the `ref.read(workspaceNavigationProvider(...)).visit(...)`
     statement (`:1556-1573`). After the block add:

```dart
    recordWorkspaceLocation(
      supplementKey == null || selectedHash == null
          ? null
          : WorkspaceFocus(
              repositoryPath: widget.repoPath,
              sessionEpoch: connection.sessionEpoch,
              kind: _selectedHashes.length > 1
                  ? WorkspaceFocusKind.range
                  : WorkspaceFocusKind.revision,
              identity: selectedHash,
              secondaryIdentity: _selectedHashes.length > 1
                  ? _selectedHashes.last
                  : _effPath,
              panelIndex: 1,
            ),
      active: widget.isActive,
    );
```

     The `rangeEnd` computation in the callback (`:1534-1536`) stays for the supplement label.

2.2. **History regression tests (`test/history_actions_test.dart`).** Extend `_pump` (`:168`)
     with `bool isActive = true`, passed to `HistoryView`. Add, in the group that holds the
     reveal test (`:740`):

     * *"records a location once: a rebuild after a foreign visit adds nothing"* — pump two
       commits with `connected: true`; tap the first row; `await tester.pump()`; read
       `workspaceNavigationProvider(WorkspaceSessionKey(_repo, 1))` and expect `locations` to
       equal `[revision(head)]`; then `.visit(WorkspaceFocus(kind: branch, identity: 'main',
       panelIndex: 2, …))` through the notifier; `await tester.pump()` five times; expect
       `locations` to equal exactly `[revision(head), branch(main)]` and `index` to be 1.
     * *"records nothing while inactive"* — the same pump with `isActive: false`; tap the row
       (or set the selection through the same tap; if an inactive panel cannot be tapped in the
       harness, drive `_handleRowTap` through a reveal instead and say so in the execution
       record); pump five frames; expect `locations` to be empty.

2.3. **Branches (`lib/features/branches/branches_view.dart`).** `_BranchesViewState with
     WorkspaceLocationRecorder`; delete the `visit` statement (`:443-462`) from the callback; add
     after the block a `recordWorkspaceLocation` call with the same `WorkspaceFocus` (kind
     `revision` for a tag, else `branch`; identity `selectedRef.name`; secondary
     `base?.refName`; `panelIndex: 2`), null when `selectedRef == null || supplementKey ==
     null`, `active: widget.isActive`.
2.4. **Branches tests (`test/branches_view_test.dart`).** `_pump` (`:81`) gains
     `bool connected = false` and `bool isActive = true`; when connected it overrides
     `connectionProvider` with a stub identical in shape to `_StubConnection` in
     `test/history_actions_test.dart:161` (`phase: connected, repoPath: _repo, sessionEpoch:
     1`). Add the same two cases as 2.2, selecting a branch row by tap; the foreign visit is a
     `revision` on `panelIndex: 1`.
2.5. **Stashes (`lib/features/stash/stash_view.dart`).** `_StashViewState with
     WorkspaceLocationRecorder`; delete the `visit` statement (`:372-388`); add the call with kind
     `stash`, identity `selEntry.oid`, `panelIndex: 3`, `active: widget.isActive`.
2.6. **Stash tests (`test/stash_view_test.dart`).** `_pump` (`:141`) gains `connected` and
     `isActive` as in 2.4; add the two cases, selecting a stash row by tap.
2.7. **Worktrees (`lib/features/worktrees/worktrees_view.dart`).** `_WorktreesViewState with
     WorkspaceLocationRecorder`; delete the `visit` statement (`:639-655`); add the call with kind
     `worktree`, identity `tabs.selected ?? _selectedOverviewPath`, `panelIndex:
     kWorktreesPageIndex`, `active: widget.isActive`.
2.8. **Worktree tests (`test/worktrees_view_test.dart`).** The pump helper that already overrides
     `connectionProvider` (`:519`) gains `isActive`; add the two cases, selecting a worktree row
     by tap.
2.9. Verify: `flutter analyze`; the four test files; then the full suite:
     `flutter test > "$LOG" 2>&1; STATUS=$?` and read `$LOG` for `[E]` and the summary line.
     Commit.

### Phase 3 — On-device confirmation and record closure

3.1. `./build_macos.sh --unsigned`; launch the built app.
3.2. Run the three-step reproduction on the fixture the 0064 gate used (Branches on Browse →
     select `master` → ⌘2 → select a commit) and sample `ps -p <pid> -o %cpu=` at 1.5 s intervals
     for 10 s. **Accept:** every sample ≤ 5.0. The scratch driver `spin_min.py` from the 0064
     diagnostic does exactly this unattended and prints the samples; a maintainer-run of the same
     steps by hand is equally valid. Record the samples verbatim.
3.3. Also confirm Back/Forward by hand: select a branch, switch to History, select a commit,
     press Back twice and Forward twice; each lands on the entry it does on the unfixed build
     (branch → History panel → commit). Record what was seen.
3.4. Update this plan's status and the MADR's status (`accepted`) and `verified` dates, the two
     `docs/README.md` rows, and the execution record. `dart run tool/records.dart check` must
     print `0 finding(s)`. Commit.

## Verification

| Check | Command | Pass condition |
|---|---|---|
| Static analysis | `flutter analyze` | `No issues found!` |
| Notifier | `flutter test test/workspace_navigation_test.dart` | all pass; the stale-echo test no longer exists |
| Panels | `flutter test test/history_actions_test.dart test/branches_view_test.dart test/stash_view_test.dart test/worktrees_view_test.dart` | all pass, including the eight new cases |
| Negative | Phase 0 in the scratch clone | both History cases fail on the unfixed tree, with the messages recorded |
| Full suite | `flutter test > "$LOG" 2>&1; STATUS=$?` | `STATUS` 0; `grep -c '\[E\]' "$LOG"` prints 0 |
| Device | Phase 3.2 | ten samples, each ≤ 5.0% |
| Records | `dart run tool/records.dart check` | `0 finding(s)` |

## Acceptance Criteria

* AC1 — The History regression test fails on the unfixed tree (Phase 0) and passes after Phase 2.
* AC2 — All eight panel cases pass; no existing test is loosened or skipped.
* AC3 — `_staleEcho` no longer appears in `lib/` (`grep -rn _staleEcho lib` prints nothing).
* AC4 — `AppShell._pages` watches the navigation provider only through `select`.
* AC5 — The on-device reproduction reads ≤ 5% in every sample over 10 s.
* AC6 — Back/Forward land where they do on the unfixed build (Phase 3.3).
* AC7 — The full suite is green with 0 `[E]`; the records check is clean; both records carry
  their final status.

## Rollout and Rollback

Rollout is the next `./build_macos.sh --unsigned --install`; there is no data migration, and the
navigation history is in-memory session state.

Rollback is `git revert` of the three phase commits, newest first. The regression tests revert
with Phase 2, so a rollback cannot leave a test that fails by design. Nothing persisted changes
shape.

## Execution record

* **Phase 0 (2026-09-22).** Scratch clone of `718a354`; the two History cases from step 2.2
  added by a scratch applier (anchored edits, each asserted to match exactly once); nothing else
  changed. `flutter test test/history_actions_test.dart --plain-name "(0065)"` exited 1:
  * `records a location once: a rebuild after a foreign visit adds nothing (0065)` —
    `Expected: [Instance of 'WorkspaceFocus', Instance of 'WorkspaceFocus']` /
    `Actual: [Instance of 'WorkspaceFocus', Instance of 'WorkspaceFocus', Instance of
    'WorkspaceFocus']` / `Which: at location [2] … which longer than expected` /
    `an unchanged selection must not be re-recorded on rebuild`. The third entry is History
    re-recording its commit on the rebuild: the defect.
  * `records nothing while it is not the active page (0065)` — `Expected: empty` /
    `Actual: [Instance of 'WorkspaceFocus']` / `a hidden panel never records where the user
    is`.
  * Two harness corrections were needed before the tests measured the defect rather than
    themselves, both carried into step 2.2: a connected session renders the commit subject a
    second time outside the list, so the row is found as the `ListView`'s descendant; and the
    panel's `PanelShortcuts` are empty while inactive, so the inactive case proves its selection
    by the canvas placeholder ("Select a commit") disappearing, not by a handler. Both earlier
    runs failed on those harness errors, not on the assertion, and are not evidence.
* **Phase 1 (2026-09-22).** As written: `workspace_location_recorder.dart` added with the
  plan's code; `_staleEcho`, its `visit` guard, its `reveal` and `_restore` assignments and the
  `markUnavailable` comment removed from `workspace_navigation.dart`; `AppShell._pages` watches
  `select((s) => s.locations.isEmpty)`. In `test/workspace_navigation_test.dart` the stale-echo
  test is replaced by "a restore keeps forward through the adapter's re-record" (Back, the
  adapter re-records the restored location, forward survives, a new visit truncates) and
  "revealing the current location adds no entry but marks it pending" is added — step 1.4's
  read of the existing reveal test found it covers only a *new* location.
  `flutter analyze`: `No issues found! (ran in 5.6s)`. `dart format --set-exit-if-changed` on the
  four files: `0 changed`. `flutter test test/workspace_navigation_test.dart
  test/app_shell_test.dart test/app_shell_undo_test.dart`: `+19: All tests passed!`, 0 `[E]`.
* **Phase 2 (2026-09-22).** The four panels mix in `WorkspaceLocationRecorder`; each callback
  keeps its supplement `publish` and loses its `visit`; each `build` makes one
  `recordWorkspaceLocation` call with the location expression the callback used to build,
  gated on `widget.isActive`. Worktrees' call sits after `final connection =
  ref.watch(connectionProvider)` (the callback read the connection itself) and is null while
  the list has no data, as the callback's early return was. The eight test cases are as written
  in steps 2.2–2.8, with three harness facts learned on the way and now in the tests: Branches
  and Stashes prove their selection through the published supplement (`branchLabel ==
  'Selected: feature'`, `selectionLabel` starting `Stash: stash@{0}`) since neither panel's
  shortcuts exist while inactive; Branches keeps `_pump` for its existing callers and adds
  `_pumpForNavigation` beside it; the Worktrees row waits out the double-click interval, so
  both cases pump 400 ms after the tap as that file's other tests do. `flutter analyze`: `No
  issues found! (ran in 4.9s)`. `dart format --set-exit-if-changed` on the eight files: clean
  after formatting the four test files' new code. The four panel files: `+72` then, with the
  Worktrees timing fix, `+2` for the two cases that had failed on their precondition. Full
  suite: `02:49 +4316 ~3: All tests passed!`, `[E]` count 0. `grep -rn _staleEcho lib` prints
  nothing (AC3).
* **Phase 3 (2026-09-22), steps 3.1–3.2 and 3.4.** `./build_macos.sh --unsigned` exited 0
  (the tree at `be7774e`). The scratch driver was extended to take ten `ps -o %cpu` samples at
  1.5 s intervals after the commit click, and to refuse a verdict if the process disappears
  (an empty `ps` line must not read as idle). **Seen to fail first:** on the pre-0064 build it
  reported `SPIN` with `[119.1, 115.9, 118.3, 114.6, 115.2, 114.6, 115.6, 114.7, 115.1,
  115.7]`. **On the fixed build** (Branches on Browse → select `master` → ⌘2 → select a
  commit, same fixture, 900 pt window): `[0.1, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]`,
  then `[0.0, 0.0, 0.0]` five seconds later; the capture shows the commit's diff in the
  compact canvas, the same state the unfixed build spun in. **AC5 met.**
  * **Step 3.3 (Back/Forward by hand) is the maintainer's**, per the 0064 gate's amended
    procedure (keyboard-sequence checks are maintainer-run with real keys). Until it is
    recorded here, AC6 is open and this plan stays `in-progress`; everything else is done.
  * The MADR moves to `accepted`: its Confirmation section — the failing-first tests, the
    green suite, the on-device reproduction at ≤ 5% — is met in full.
