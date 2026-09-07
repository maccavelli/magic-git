---
status: "proposed"
date: 2026-09-07
decision-makers: [Maintainer]
consulted: []
informed: [Magic Git contributors]
verified: 2026-09-07
---

# Cover the branch multi-select surface, so the two defects hiding behind it can be proven

## Context and Problem Statement

[0034](0034-MADR-debugging-pass-findings.md) found three crash-class defects of
one shape — a `mounted` guard on the wrong side of an `await`. **F4 is fixed**
(commit `44169ac`): reproduced first, guarded in both sheets, mirrored tests.
**F2 and F3 are not**, and the reason is not the fix. It is that neither can be
reproduced.

Both live behind the branches panel's **multi-select batch bar**, which renders
only when `_multiSel.isMulti` (`branches_view.dart:540`). Attempting to reach it
from a widget test failed repeatedly, and the eventual cause was not the one the
symptoms suggested.

0034's Confirmation section is explicit that a guard added without a
reproduction is "being added on faith". That standard is what makes this a
decision rather than a chore: the cheap path is to add two `mounted` checks and
move on, and this record argues against it.

### What the investigation actually found

Four hypotheses were tested and three were wrong. Recorded because each looked
right:

1. **"Modifier synthesis doesn't work in `flutter_test`."** Wrong, and measured:

   ```
   PROBE before:            shift=false
   PROBE after plain down:  shift=true
   PROBE after macos down:  shift=true
   PROBE meta down:         meta=true
   ```

   `sendKeyDownEvent` sets `HardwareKeyboard.instance` correctly, with or
   without `platform: 'macos'`.

2. **"The branch list isn't focused, so keys don't route."** Wrong:

   ```
   PROBE focus before tap: _ModalScopeState<dynamic> Focus Scope
   PROBE focus after tap:  branch-list
   ```

   Tapping a row focuses the list (`branch_navigator.dart:448`), exactly as the
   production code intends.

3. **"`isActive` or `busy` gates the key handler."** Wrong — `isActive`
   defaults to `true` (`branches_view.dart:83`, `branch_navigator.dart:321`)
   and nothing sets `busy` in the fixture.

4. **The actual cause — multi-select is Review-mode-only, by design.**
   `branch_navigator.dart:450`:

   ```dart
   if (onMulti != null && widget.mode == BranchWorkspaceMode.review) {
   ```

   In `browse` mode — the default, since `workspacePrefs?.lastMode` is unset in
   a fixture (`branches_view.dart:258-262`) — `onMultiSelect` is **never
   called**. Shift-arrow and command-click both fall through to the
   single-selection path, silently. Nothing is broken; the test was driving a
   surface that does not exist in that mode.

### The technique, demonstrated

Adding one line ahead of the interaction makes the whole surface reachable:

```dart
await tester.tap(find.text('Review'));      // branch_navigator.dart:925
await tester.pumpAndSettle();
await tester.tap(find.text('main'));        // focuses branch-list, sets cursor
await tester.pumpAndSettle();
await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
```

Measured result:

```
PROBE switched to Review mode
PROBE focus after tap:  branch-list
PROBE selected:         1
PROBE after shift+down: 2 selected
PROBE buttons:          Pin, Unpin, Hide, Delete if merged…
```

This is a **demonstrated** technique, not a proposal. It was run against the
current tree; the probe was then removed and the tree left clean.

### The coverage gap this exposes

Searching the whole suite for `BranchMultiSelection`, `multiSelection` or
`onMultiSelect` returns **two files**, `branches_multi_select_test.dart` and
`branch_review_query_test.dart`, and **both have zero `testWidgets`**. They test
the selection *model* — `replace`, `toggle`, `rangeTo`, `preserveAfterRefresh`
— and nothing else.

So the batch bar's four actions — **Pin, Unpin, Hide, Delete if merged…** —
have no coverage *through the batch path*. Stated precisely, because the first
draft of this record overstated it: the **pieces** are covered —
`branch_bulk_delete_sheet_test.dart` drives the delete sheet in isolation (5
widget tests), `pinned_branches_test.dart` covers single-branch pin (3), and
`branch_workspace_prefs_test.dart` / `branch_hidden_display_test.dart` cover the
prefs and hidden-display models (17 unit tests between them).

What is uncovered is the **wiring**: nothing anywhere reaches `_batchHide`,
`_batchPin` or `_bulkDeleteSelected` — verified by searching the whole suite for
those names, which returns nothing. Every component works in isolation and no
test proves the batch bar connects them to a selection.

That is why F4 took minutes and F2/F3 could not be done: F4 sat behind a
dropdown the existing tests already drive.

### Does multi-select actually work? Measured: yes, for three of four actions

The coverage gap raises the obvious question, so it was answered directly
rather than left to the plan. A throwaway probe drove the real panel — Review
mode, shift-extended selection of two branches — against a durable
`RepositoryUiIdentity.ssh` and a mocked `SharedPreferences`, then read the
persisted prefs back:

```
PROBE bar: Pin, Unpin, Hide, Delete if merged…
PROBE pinned after batch Pin:   [feature, main]
PROBE pinned after batch Unpin: []
PROBE hidden after batch Hide:  [feature]
PROBE exception: null
```

* **Pin** — both selected branches pinned, persisted.
* **Unpin** — both cleared, persisted.
* **Hide** — `feature` hidden and persisted; `main` correctly **skipped**
  because it is HEAD, which is the documented rule (0003: "Current, pinned,
  protected/default, and worktree-held branches cannot be hidden").
* No exception on any of them.

**"Delete if merged…" was NOT verified.** The probe tapped it and nothing
happened, and the reason is the fixture, not the feature: the panel reported
*"No base available"*, and the button is gated `busy || base == null ? null :
…` (`branches_view.dart:682`), so it was disabled and the tap was a no-op. A
first read of the probe output looked like the sheet had opened — the finder
matched the button's own label. **Recorded as unverified rather than counted as
working**, and the plan must give the fixture a comparison base to exercise it.

So the feature is not broken, and this record's job is to stop that being a
matter of opinion: three actions demonstrably work today, one is unproven, and
**no test guards any of them against tomorrow**.

### The two defects, restated

Both from 0034, unchanged and still unreproduced:

* **F2 — `_batchHide` (`branches_view.dart:710`).** `await
  _updateWorkspacePrefs(…)` at `:756` (three awaits inside, including disk),
  then `ref.invalidate(…)` at `:760` and `setState(…)` at `:774` with no
  `mounted` check — while `:778` checks `mounted` for the *next* statement.
  `ref` after dispose throws, and so does `setState`.
* **F3 — `_bulkDeleteSelected` (`branches_view.dart:799`).**
  `if (!mounted) return;` at `:924` guards *before* `await
  showBranchBulkDeleteSheet(…)` at `:925` — a modal, so the window is as long
  as the user takes — and `_refresh()` + `setState(…)` at `:934-935` never
  re-check.

## Decision Drivers

* **A guard added without a reproduction is a guess.** 0034 says so, and F4
  proved the point: the reproduction turned a "traced by reading" finding into
  an observed `setState() called after dispose()` in both sheet States.
* **The gap is worth more than the two fixes.** The four batch actions are
  wired to their (well-tested) components by three handlers that no test
  reaches — and both defects live in exactly that unreached wiring.
* **The technique is one line.** `tap(find.text('Review'))`. The cost of this
  work is almost entirely in *knowing* that, which this record now captures.
* **Don't let a discovery stay tacit.** The Review-mode gate is correct design
  and completely invisible from the test side. Without writing it down, the
  next person repeats the same four hypotheses.
* **Fixture honesty.** `_refs` in `branches_view_guards_test.dart` has one
  eligible branch (`main` is HEAD and is skipped by `_batchHide`). A batch test
  needs a fixture that actually exercises batch behaviour.

## Considered Options

* **A. Build the multi-select technique, then fix F2 and F3 on top of it.**
* **B. Fix F2 and F3 with guards, no reproduction.** Two lines, minutes.
* **C. Build coverage for the batch surface as its own piece of work**, and
  leave F2/F3 to a later pass.
* **D. Reproduce F2/F3 by making the private methods visible to tests**
  (`@visibleForTesting`), bypassing the UI entirely.

## Decision Outcome

Chosen option: **A** — build the technique, then use it for F2 and F3 — because
the technique is now known and cheap, it is the only route that meets 0034's own
standard, and it leaves behind coverage for four actions that have none.

**Ordering (maintainer's priority, 2026-09-07): proving multi-select works comes
first.** The steps below are unchanged in content but deliberately ordered so
the feature's own coverage lands before the two guards, rather than falling out
of them. F2 and F3 are then written on top of an entry point that already
exists.

Shape of the work:

1. **A shared entry point for the batch bar** in
   `branches_view_guards_test.dart` — a helper that switches to Review, selects
   a row, and shift-extends, returning with the bar on screen. One place for the
   Review-mode knowledge, so the next batch test does not rediscover it.
2. **A fixture that can exercise a batch** — at least two branches eligible for
   hide and delete (the current `_refs` has one, since `main` is HEAD).
3. **Coverage for the four batch actions — first, not last.** Pin, Unpin and
   Hide assert the persisted prefs (the probe above is the shape, and its
   expected values are already known: `[feature, main]`, `[]`, `[feature]`,
   with HEAD skipped). "Delete if merged…" needs a fixture with a comparison
   base before it can be driven at all — that is the one action whose behaviour
   is currently unproven.
4. **F2 and F3 reproduced**, each seen to throw before its guard, following
   F4's pattern: park the awaited work (F2: override
   `repositoryUiIdentityProvider` with a `Completer`; F3: hold the bulk-delete
   sheet open), dispose the panel, release, assert no exception.
5. **The two guards**, each with the comment naming the finding, as F4 has.

Step 3 is the part that would not exist if only F2 and F3 were fixed, and it is
both the reason to choose A over C and the reason it now runs first.

### Consequences

* Good, because it meets the standard 0034 set instead of quietly lowering it.
* Good, because the Review-mode gate stops being tacit knowledge; the helper's
  doc comment is where the four wrong hypotheses get their answer.
* Good, because the batch handlers gain their first coverage — the components
  they drive are already tested, so this closes the wiring, which is where F2
  and F3 both live.
* Bad, because it is materially more work than "add two `mounted` checks", for
  two defects that are real but narrow (both need the panel disposed inside a
  specific await).
* Bad, because F2's reproduction depends on `_updateWorkspacePrefs` returning
  through the `identity == null` early path (`branches_view.dart:992`) — a real
  path, but the test is then pinned to an implementation detail one refactor
  could move. It should say so in a comment.
* Neutral, because none of this changes behaviour: F2 and F3 are guards, and
  everything else is test code.

### Confirmation

* Each reproduction **seen to fail first**, with the failure text recorded — as
  F4's was (`setState() called after dispose(): _CloneRepositorySheetState…`).
  A reproduction that only ever passes is not evidence.
* **Read the whole failure list**, not the first line. Two earlier phases of
  this session nearly drew wrong conclusions from a truncated test log; the
  batch bar's actions overlap enough that one mutation may break several tests.
* `flutter analyze` clean; `dart format` clean; full suite green.
* The four batch-action tests must each be shown to fail against a deliberately
  broken handler, or they only prove the bar renders.

## Rejected options

### B. Fix the guards without reproducing

* Good, because it is two lines and closes the findings today.
* Bad, because it is exactly what 0034 warns against, and F4 is the
  counter-example: the same reasoning that "traced" F2 and F3 also produced
  0034's F1 headline **and** a claim in 0033 Phase 0a that turned out to be
  **wrong** when finally executed. Reading is not evidence.
* Bad, because it leaves four batch actions uncovered, so the next defect there
  is found the same way — by inspection, months later.

### C. Coverage as its own piece, F2/F3 later

* Good, because it separates a testing investment from a bug fix.
* Bad, because the two defects are the reason the gap was found, and deferring
  them means paying the context cost twice.

### D. `@visibleForTesting` on the private methods

* Good, because it is the shortest path to a reproduction.
* Bad, because it proves the method misbehaves when called directly, not that a
  user can reach it — and the multi-select bar is precisely the reachability
  that is untested.
* Bad, because it widens a private API to serve a test, when the public path
  turned out to need one extra line.

## More Information

* [0034-MADR-debugging-pass-findings.md](0034-MADR-debugging-pass-findings.md)
  — F2, F3 and the resolved F4, whose method this record follows.
* Code: `branch_navigator.dart:450` (the Review-mode gate), `:448` (row tap
  focuses the list), `:498-512` (`_moveSelection`), `:925` (the Review control);
  `branches_view.dart:540` (`isMulti` gates the bar), `:631-690` (the four batch
  actions), `:710` (F2), `:799` (F3), `:986` (`_updateWorkspacePrefs`).
* Tests: `branches_view_guards_test.dart` (`_pump` is the fixture to extend),
  `branches_multi_select_test.dart` and `branch_review_query_test.dart` (the
  model-only coverage this record measures).
* All probe output quoted here was produced on 2026-09-07 against the tree at
  commit `44169ac`, with temporary tests that were removed afterwards; the
  working tree was left clean and green.
