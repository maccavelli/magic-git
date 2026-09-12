---
status: "proposed"
date: 2026-09-12
associated-madr: "0049-MADR-worktree-row-overflows-the-navigator-pane.md"
---

# Implement: bound the worktree row, bound the chip, clip the pane

Associated MADR: [0049-MADR-worktree-row-overflows-the-navigator-pane.md](0049-MADR-worktree-row-overflows-the-navigator-pane.md)

## Goal

A worktree row must stay inside the navigator pane at **every** width the user can drag it to
(240–720 pt), however long the worktree's name, branch or lock reason. No pane may paint over
another. Both halves of the cause are fixed — the unbounded name and the unbounded chip — and the
pane is clipped so that any *future* overflow truncates at the divider instead of scribbling on the
canvas.

## Scope

**In**

| File | Change |
| --- | --- |
| `lib/features/common/label_chip.dart` | a maximum width and an ellipsizing label |
| `lib/features/worktrees/worktrees_view.dart` | the overview row: flexible name, flexible branch chip, tooltips |
| `lib/features/common/resizable_master_detail.dart` | clip the leading pane, both axes |
| `test/worktree_row_overflow_test.dart` | **new** — the reported case, guarded |
| `test/resizable_pane_clip_test.dart` | **new** — the containment guard |
| `test/label_chip_row_overflow_test.dart` | **new** — the other `LabelChip` surfaces |
| `tool/mutations/0049-row-bounding.json` | **new** catalogue |

**Out**

* **The trailing (canvas) pane is not clipped.** It has the same exposure, but nothing has been shown
  to overflow it, and clipping the canvas would hide overflow in the pane where content is *supposed*
  to be wide (diffs, history). Named here so the asymmetry is deliberate rather than forgotten.
* **History's capped `+N` strip** (MADR 0049 option C). Revisit only if rows still read as crowded at
  240 pt after this lands — the measurement in 1.6 is what decides.
* No change to what a row *shows*: same name, same chips, same order.

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

### Phase 0 — preconditions, and the measurement re-established

0.1 `flutter --version | head -1` matches `FLUTTER_VERSION` in `build_macos.sh` (**3.47.2**);
`flutter pub get --enforce-lockfile` reports `Got dependencies!`; `git status --short` is empty.

0.2 Baseline `flutter test` in full, recorded.

0.3 **Re-establish the reproduction before changing anything.** Write
`test/worktree_row_overflow_test.dart` (its final content, per 1.4) and run it against the unmodified
tree. Every overflow case must fail, and the record captures the pixel counts at **240**, **320** and
**520** pt. MADR 0049 F4 measured 944 px at the harness's 520; the other two widths are new data the
plan needs, because 240 is the width the criteria are written against.

*(The test is committed in Phase 1, with the fix that makes it pass; a red test is never committed.)*

### Phase 1 — bound the row and the chip

**Both halves land together.** MADR 0049 F4 measured each alone as insufficient (147 px and 551 px
of residual overflow), so splitting them would leave a phase whose own guard cannot pass.

1.1 `lib/features/common/label_chip.dart` — the chip bounds itself:

```dart
class LabelChip extends StatelessWidget {
  const LabelChip(
    this.text, {
    super.key,
    required this.color,
    this.icon,
    this.maxWidth = defaultMaxWidth,
  });

  /// Widest a chip may draw before its label ellipsizes.
  ///
  /// 160 is chosen against the NARROWEST pane the user can drag to (240 pt,
  /// `RepositoryWorkspacePrefs.minNavigatorWidth`): 32 pt of row padding, a
  /// 16 pt icon and its 10 pt gap leave ~182 pt, so a chip that took all 160
  /// would still leave the name a readable remainder — and in the row the chip
  /// is flexible anyway, so it only reaches this cap where it is not.
  static const double defaultMaxWidth = 160;

  final double maxWidth;
  …
}
```

and in `build`, the `Container` gains `constraints: BoxConstraints(maxWidth: maxWidth)` while its
`Text` becomes `Flexible(child: Text(text, maxLines: 1, softWrap: false, overflow:
TextOverflow.ellipsis, …))`.

> `Flexible` here is safe precisely where History's `ref_chip.dart:129-131` warns it is not: that
> comment is about a flex child of a **min-sized, right-aligned strip**, which can collapse to zero.
> Here the `Flexible` sits inside the chip's own `Container`, which now has a bounded maximum, so the
> label has a definite width to ellipsize into.

1.2 `lib/features/worktrees/worktrees_view.dart:1066-1110` — the row's inner `Row`:

* the name becomes
  `Flexible(flex: 2, child: MacosTooltip(message: wt.name, child: Text(wt.name, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis, style: …)))`;
* the branch chip becomes
  `Flexible(flex: 1, child: MacosTooltip(message: wt.branchLabel, child: LabelChip(wt.branchLabel, color: MacosColors.systemBlueColor)))`;
* the locked chip gains `MacosTooltip(message: wt.lockReason ?? 'locked', …)` — its text is the one
  chip whose content is arbitrary user input;
* `main worktree`, `open` and `missing` are left exactly as they are: fixed short strings, now capped
  by 1.1 in any case.

Flex 2:1 is deliberate — the name is the row's subject and the branch is its qualifier, so under
pressure the name keeps twice the remainder. Both still ellipsize.

1.3 The tooltips are why truncation is acceptable: the branch label appears nowhere else in the row,
and the lock reason nowhere else in the panel. The name's full text also remains in the detail pane's
`SelectableText` (`worktrees_view.dart:1183`).

1.4 `test/worktree_row_overflow_test.dart` — fixtures built from `GitWorktree` directly, pumped
through the real `WorktreesView` using `worktrees_view_test.dart`'s existing `pump(tester, data:,
extraOverrides:)` harness, with the pane pinned by overriding
`repositoryWorkspacePrefsProvider(repo)`:

* `a long name and branch do not overflow the navigator at its minimum width` (240 pt) —
  `expect(tester.takeException(), isNull)`
* `… at the default width` (320 pt)
* `… at the maximum width` (720 pt)
* `the name ellipsizes rather than widening the row` — the name `Text` has `maxLines: 1` and
  `TextOverflow.ellipsis`
* `the full name and branch stay reachable in tooltips`
* `a lock reason of arbitrary length does not overflow` — `isLocked` with a 200-character reason
* `the detail pane's chips wrap rather than overflow` — the `Wrap` cluster at
  `worktrees_view.dart:1185-1204`, same pathological fixture

1.5 **Seen to fail**, in a detached scratch worktree, three times — once per half and once for both,
reproducing MADR 0049 F4's table against this plan's own guard:

| Reverted | Expected |
| --- | --- |
| the name's `Flexible` + ellipsis | `A RenderFlex overflowed by …` |
| `LabelChip`'s `maxWidth` + ellipsis | `A RenderFlex overflowed by …` |
| both | the largest overflow of the three |

1.6 **Measure the remainder.** With the fix in place, record at 240 pt how many characters of the
name survive alongside the chips. If the name is truncated below ~12 characters with the ordinary
chip set (branch + one state chip), that is the signal MADR 0049 named for adopting History's `+N`
strip — report it as a deviation rather than absorbing it.

1.7 Gate (rule 3), then **commit (code)**.

### Phase 2 — clip the navigator pane

2.1 `lib/features/common/resizable_master_detail.dart` — in **both** layout branches (horizontal at
`:145-149`, vertical at `:168-172`), the leading pane becomes:

```dart
SizedBox(
  width: visibleExtent,
  // A SizedBox bounds LAYOUT, not painting: a child that overflows its
  // constraint still paints across the divider and onto the canvas, which is
  // how a too-wide worktree row came to draw over the detail pane (MADR 0049
  // F6). The clip makes an overflow truncate at the divider instead — it
  // repairs nothing, it contains everything.
  child: widget.collapsed ? null : ClipRect(child: widget.leading),
),
```

2.2 `test/resizable_pane_clip_test.dart`:

* `an over-wide leading child is clipped at the pane edge` — pump a `ResizablePanePair` whose leading
  is a deliberately over-wide box, and assert the pane paints a clip:
  `expect(tester.renderObject(find.byType(ResizablePanePair)), paints..clipRect())`. If the `paints`
  matcher proves awkward against the `Stack`, fall back to asserting a `ClipRect` ancestor of the
  leading child whose size equals `visibleExtent` — and say in the record which form was used and why.
* `the same holds on the vertical axis`
* `a leading child that fits is unaffected` — the control.

2.3 **Seen to fail** with the `ClipRect` removed in a scratch worktree.

2.4 Gate, then **commit (code)**.

### Phase 3 — the other `LabelChip` surfaces

MADR 0049 F8 lists `branch_navigator.dart` (four sites), `stash_view.dart` and
`connection_switcher.dart`; its "Not established" says nobody has shown whether any of them overflows
today. This phase answers that with a measurement rather than an assumption.

3.1 `test/label_chip_row_overflow_test.dart` — the same pathological data through each surface, at
240 pt: a branch row with a long name and a long "checked out elsewhere" chip; a stash row with a long
message; a switcher row with a long repository label. Each asserts
`expect(tester.takeException(), isNull)`.

3.2 Run it **before** touching those files and record the result per surface. Then:

* any surface that overflows is fixed with Phase 1's pattern (flexible subject, bounded chip,
  tooltip) in this phase;
* any surface that does not is left alone, and its test stands as a regression guard. Say so
  explicitly in the record — "not broken" is a finding, not a gap.

3.3 Gate, then **commit (code)**.

### Phase 4 — the sabotage catalogue

4.1 `tool/mutations/0049-row-bounding.json`, each entry removing exactly one guarantee. Every `find`
string is asserted to occur exactly once in its file before the catalogue is written.

| Label | Removes |
| --- | --- |
| `p1: the worktree name is unbounded again` | the name's `Flexible` |
| `p1: the name no longer ellipsizes` | `overflow: TextOverflow.ellipsis` on the name |
| `p1: the branch chip is unbounded` | the branch chip's `Flexible` |
| `p1: a chip may draw at any width` | `LabelChip`'s `maxWidth` constraint |
| `p1: a chip's label does not ellipsize` | the `Flexible` + ellipsis inside `LabelChip` |
| `p1: the branch chip loses its tooltip` | the branch chip's `MacosTooltip` |
| `p2: the navigator pane is not clipped` | the horizontal `ClipRect` |
| `p2: the vertical pane is not clipped` | the vertical `ClipRect` |

4.2 `tool/mutate.py --check tool/mutations/0049-row-bounding.json` reports every entry sound, then
`tool/mutate.py tool/mutations/0049-row-bounding.json` must end
`N killed, 0 survived, 0 did not apply, 0 did not compile, 0 observed by no test`.

4.3 **Commit (code)** — the catalogue only.

### Phase 5 — close the records

5.1 MADR 0049 → `verified:` today, and its **"Not established"** paragraph replaced by Phase 3's
measured answer. This plan → `status: complete` with its execution record. README rows for 0049.
**Commit (docs).**

## Verification

The whole-plan gate:

```sh
flutter --version | head -1                       # Flutter 3.47.2
flutter analyze                                   # No issues found
flutter test                                      # all pass
flutter test test/worktree_row_overflow_test.dart test/resizable_pane_clip_test.dart \
  test/label_chip_row_overflow_test.dart test/worktrees_view_test.dart \
  test/branches_view_test.dart test/stash_view_test.dart
flutter test test/workspace_golden_test.dart      # the 48 goldens — see Risks
tool/mutate.py --check tool/mutations/0049-row-bounding.json
tool/mutate.py tool/mutations/0049-row-bounding.json
```

Exit statuses are captured, never piped into a filter.

## Acceptance Criteria

1. With a 60-character name and a 50-character branch, the Worktrees overview raises **no**
   `RenderFlex` overflow at 240, 320 or 720 pt.
2. The same holds with a 200-character lock reason, and in the detail pane's `Wrap` cluster.
3. The row's name ellipsizes with `maxLines: 1`, and its full text is reachable in a tooltip.
4. The branch chip ellipsizes, and its full label is reachable in a tooltip.
5. `LabelChip` never draws wider than `LabelChip.defaultMaxWidth` unless a caller passes more.
6. `ResizablePanePair` clips its leading pane on **both** axes, guarded by a test that was seen to
   fail with the clip removed.
7. Every guard in phases 1–3 has been seen to fail against the unfixed code, with the output recorded.
8. Phase 3 reports, per surface, whether it overflowed before the chip change — a measured answer to
   the MADR's open question, not an assumption.
9. Catalogue 0049 reports `0 survived, 0 did not apply`, and every other catalogue still does.
10. `flutter analyze` clean, full suite green, every staged Dart file formatted.
11. The 48 workspace goldens either pass untouched, or any that shift are inspected and their new
    state justified in the record — never regenerated wholesale.
12. Manually, in the running app: the reported worktree row at the default width and dragged to the
    minimum, with nothing crossing the divider, and the full branch name available on hover.

## Rollout and Rollback

Five commits, code and docs never mixed. **The phases stack loosely**: 2 and 3 are independent of each
other, but both read Phase 1's chip; 4 needs all of them.

Rollback reverts code commits newest-first (`git revert --no-edit <sha>`), never resets and never
rewrites history. **Nothing to clean up**: no persisted state, no host state, no schema. A rolled-back
build simply overflows again.

Nothing is pushed unless the maintainer asks in that same turn.

## Risks

* **The 48 workspace goldens may shift.** Bounding a chip changes pixels wherever a chip was wider
  than its new cap. A shifted golden is inspected and only accepted if the diff *is* the intended
  truncation; a wholesale `--update-goldens` would discard the check this plan depends on.
* **`Flexible` collapsing to zero** — History's `ref_chip.dart:129-131` records this exact trap for a
  min-sized strip. 1.1 places the `Flexible` inside a bounded `Container`, and 1.2 places the chip's
  `Flexible` inside a row that is itself bounded by `Expanded`; the guards at 240 pt are what prove it.
* **Nested `MacosTooltip`s**: `branch_navigator.dart:1664` already wraps a `LabelChip` in a tooltip, so
  the tooltip belongs at the call site (as in 1.2) and never inside `LabelChip` itself.
* **Test-font widths are not real widths.** Overflow figures from widget tests are inflated; they
  prove presence or absence, not visual severity. Criterion 12 is the human check.
* **240 pt may simply be too narrow for a long branch plus four state chips.** If 1.6's measurement
  shows the name squeezed below readability, that is a deviation and the `+N` strip is the answer,
  not a smaller font or a wider minimum.
