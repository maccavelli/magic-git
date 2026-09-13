---
status: "in-progress"
date: 2026-09-13
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

MADR 0049 F8 lists `branch_navigator.dart`, `stash_view.dart` and `connection_switcher.dart` — the
right files, at `lib/features/switcher/` for the last of them and with five `LabelChip` sites in
branches, not four (deviation (c)). Its "Not established" says nobody has shown whether any of them
overflows today. This phase answers that with a measurement rather than an assumption.

**And it measures one more thing.** Deviation (c) found a second, unbounded chip widget the MADR never
counted — `ForgeLabelChip` / `MiniLabelChip`, in `project_sections.dart`, `github_panel.dart` and
`gitlab_panel.dart`. They are measured here too, and bounded only if the measurement shows an
overflow.

3.1 `test/label_chip_row_overflow_test.dart` — the same pathological data through each surface, at
240 pt: a branch row with a long name and a long "checked out elsewhere" chip; a stash row with a long
message; a switcher row with a long repository label. Plus the forge chips, whose failure mode is
different: a `Wrap` cannot split one child, so the fixture is a **single** label longer than the pane
rather than many. Each asserts `expect(tester.takeException(), isNull)`. Where a surface cannot be
pumped in isolation, say so in the record and name what was measured instead — an unmeasured surface
is reported, never skipped silently.

3.2 Run it **before** touching those files and record the result per surface. Then:

* any surface that overflows is fixed with Phase 1's pattern (flexible subject, bounded chip,
  tooltip) in this phase;
* any surface that does not is left alone, and its test stands as a regression guard. Say so
  explicitly in the record — "not broken" is a finding, not a gap.

3.3 Gate, then **commit (code)**.

### Phase 4 — the sabotage catalogue

4.1 `tool/mutations/0049-row-bounding.json`, each entry removing exactly one guarantee. Every `find`
string is asserted to occur exactly once in its file before the catalogue is written.

~~| Label | Removes |
| --- | --- |
| `p1: the worktree name is unbounded again` | the name's `Flexible` |
| `p1: the name no longer ellipsizes` | `overflow: TextOverflow.ellipsis` on the name |
| `p1: the branch chip is unbounded` | the branch chip's `Flexible` |
| `p1: a chip may draw at any width` | `LabelChip`'s `maxWidth` constraint |
| `p1: a chip's label does not ellipsize` | the `Flexible` + ellipsis inside `LabelChip` |
| `p1: the branch chip loses its tooltip` | the branch chip's `MacosTooltip` |
| `p2: the navigator pane is not clipped` | the horizontal `ClipRect` |
| `p2: the vertical pane is not clipped` | the vertical `ClipRect` |~~

**Superseded 2026-09-13.** Two entries above target code that deviation (a) deleted — the branch
chip's own `Flexible` and its call-site `MacosTooltip` — and one anchor
(`overflow: TextOverflow.ellipsis`) occurs twice in `worktrees_view.dart`, so it cannot satisfy 4.1's
uniqueness assert on its own. The catalogue that is actually written:

| Label | Removes | File |
| --- | --- | --- |
| `p1: the worktree name is unbounded again` | the name's `Flexible(flex: 2)` | `worktrees_view.dart` |
| `p1: the name no longer ellipsizes` | the name `Text`'s ellipsis (anchored with its `maxLines`/`softWrap` neighbours, so the `find` is unique) | `worktrees_view.dart` |
| `p1: a chip may draw at any width` | `LabelChip`'s `maxWidth` constraint | `label_chip.dart` |
| `p1: a chip's label does not ellipsize` | the `Flexible` + ellipsis inside `LabelChip` | `label_chip.dart` |
| `p1: a truncated chip cannot be read` | `LabelChip`'s own `MacosTooltip` (deviation (b)) | `label_chip.dart` |
| `pa: the strip no longer caps` | `take(maxVisible)` | `chip_strip.dart` |
| `pa: the +N chip is unreachable` | the `+N` `MacosTooltip` | `chip_strip.dart` |
| `pa: the row's chips stop giving way` | `chipsMayShrink: true` at the worktrees call site | `worktrees_view.dart` |
| `p2: the navigator pane is not clipped` | the horizontal `ClipRect` | `resizable_master_detail.dart` |
| `p2: the vertical pane is not clipped` | the vertical `ClipRect` | `resizable_master_detail.dart` |

`pa` entries guard deviation (a)'s `ChipStrip`; they replace the two per-chip `Flexible`/tooltip
entries with guards on the shared widget those were folded into. Phase 3 adds one entry per surface it
actually fixes.

4.2 `tool/mutate.py --check tool/mutations/0049-row-bounding.json` reports every entry sound, then
`tool/mutate.py tool/mutations/0049-row-bounding.json` must end
`N killed, 0 survived, 0 did not apply, 0 did not compile, 0 observed by no test`.

4.3 **Commit (code)** — the catalogue only.

### Phase 5 — close the records

5.1 MADR 0049 → `verified:` today, and its **"Not established"** paragraph replaced by Phase 3's
measured answer. This plan → `status: complete` with its execution record. README rows for 0049.
**Commit (docs).**

## Execution Record

### Phase 0, executed

`Flutter 3.47.2` matches `build_macos.sh`; `pub get --enforce-lockfile` clean; tree clean; baseline
suite `03:34 +4091 ~3`.

**The reproduction, before any fix** — `test/worktree_row_overflow_test.dart` run against unmodified
code, two overflows per render, both naming `worktrees_view.dart:1064` (the row's inner `Row`):

| Navigator width | Overflow |
| --- | --- |
| 240 pt (minimum) | 179 px and 1224 px |
| 320 pt (default) | 99 px and 1144 px |
| 720 pt (maximum) | 744 px |

It overflows at the **maximum** width too: the content is intrinsically wider than any pane, so no
default width would have hidden this.

### Phase 1, executed

`LabelChip` gained `maxWidth` (160) and an ellipsizing label; the row's name became `Flexible(flex: 2)`
with a tooltip; the branch chip `Flexible(flex: 1)` with a tooltip; the lock chip a tooltip. The lock
chip then had to flex as well — holding a fixed 160 pt while name and branch flexed left 18 px of
overflow at 240 pt. All four guard cases passed; gate `03:33 +4095 ~3`; commit `a84122f`.

### Deviation (a) — the name is squeezed, so the capped strip is adopted (2026-09-12)

**Found** by step 1.6's measurement, with the ordinary chip set:

| Pane | Name box | ≈ chars (test font) |
| --- | --- | --- |
| 240 pt | 97 pt | ~7 |
| 320 pt | 151 pt | ~11 |
| 720 pt | 417 pt | ~32 |

Below the ~12 the step set as the escalation threshold — in test-font units, where every glyph is one
em wide and real text fits roughly twice as many characters, so the number understates what a person
sees. Reported rather than absorbed, as 1.6 requires.

**Decision** (maintainer: "the history strip works. Adopt it here"). MADR 0049's option C is taken:
the row's chips become a capped strip that collapses the remainder into `+N`, exactly as
`RefChipStrip` does for History.

**And the discovery is generalised rather than copied.** History's strip already encodes the rule this
plan learned the hard way — *the subject flexes; the chips do not, because a flex child of a
min-sized strip can collapse to zero width* — so the strip logic is **extracted** into a shared
`ChipStrip` that both surfaces use, instead of a second implementation that will drift. Phase 1's
per-chip `Flexible` was a workaround for not having a strip, and it goes.

**Scope added:** `lib/features/common/chip_strip.dart` (new), `ref_chip.dart` delegating to it,
`worktrees_view.dart`'s chip cluster, tests for the cap and the `+N` tooltip, catalogue entries. The
History overflow guard must stay green untouched — it is what proves the extraction preserved
behaviour.

### Deviation (a), executed

**Extracted.** `lib/features/common/chip_strip.dart` — cap at `maxVisible`, collapse the rest into a
`+N` chip whose tooltip names what it swallowed. `RefChipStrip` now delegates to it and keeps its own
chip styling; the worktree row uses it with `maxVisible: 2`, chips capped at 100 pt, and entries in
priority order: branch, missing, locked, main worktree, open.

**The first design was wrong, and the sabotage said so.** `ChipStrip` began by *inferring* whether its
chips could shrink from `constraints.hasBoundedWidth`. Three sabotages were run; two were caught and
`always-shrink` was not — which exposed that the "unbounded row" test did not test what it claimed
(`Center` supplies bounded constraints, so both tests took the same branch). The inference would
therefore have switched **History's** chips to flexible as well — the collapse-to-zero its own comment
warns about — with nothing to catch it.

Shrinking is now an explicit `chipsMayShrink`, **off by default**, and the guard asserts the structure
each mode produces rather than a width that happens to come out the same:

```text
no-cap          exit=1   Expected: no matching candidates          (+N never appears)
never-shrink    exit=1   Expected: at least one matching candidate  (chips cannot give way)
always-shrink   exit=1   Expected: no matching candidates          (History's chips made flexible)
no-tooltip      exit=1                                             (hidden chips unreachable)
```

**Measured, and this is the point of the deviation.** Name width with the ordinary chip set:

| Pane | Phase 1 | Intrinsic strip | Adopted strip |
| --- | --- | --- | --- |
| 240 pt | 97.3 pt | 46.0 pt | **97.3 pt** |
| 320 pt | 150.7 pt | 126.0 pt | **150.7 pt** |
| 720 pt | 417.3 pt | 526.0 pt | **417.3 pt** |

An intrinsic strip — History's shape, adopted literally — made the name *worse* at the widths that
prompted the deviation, because chips held a fixed slice instead of yielding. With `chipsMayShrink`
the name is exactly what Phase 1 achieved, and the row additionally gains the cap: at most two chips,
the rest on a tooltip, so a worktree in four states no longer competes with its own name.

**A cap of one was tried and rejected by the existing tests.** With `maxVisible: 1`, `lists every
worktree real git reports` and `overview highlights the selected row; open tabs get a chip` failed —
`main worktree` and `open` had vanished behind `+1` at every width. Two is what History uses and what
those tests describe, and it is safe here only because the chips give way.

**Gate.** `dart format` clean, `flutter analyze` No issues, targeted `00:05 +25`, full suite
`03:28 +4099 ~3`. **Commit** `894352f`.

**Still owed:** Phases 2–5 — clip the navigator pane, measure the other `LabelChip` surfaces, the
catalogue, and the records.

### Deviation (b) — deviation (a) dropped the tooltips that made truncation acceptable (2026-09-13)

**Found** while assessing Phase 4: its entry `p1: the branch chip loses its tooltip` had nothing left
to remove. `ChipStrip.build` renders `entry.chip` bare for the chips it *shows* and tooltips only the
`+N` (`lib/features/common/chip_strip.dart:79-87`), so a branch label ellipsized at
`_rowChipMaxWidth` (100 pt), or a lock reason truncated mid-sentence, is unreadable with no hover.

**Not pre-existing — a regression from `894352f`.** A probe (`a visible branch chip is reachable by
tooltip`) was pumped through the real `WorktreesView` at 240 pt in two detached scratch worktrees:

| Tree | Result |
| --- | --- |
| `a84122f` (Phase 1) | `exit=0` — `00:00 +1: All tests passed!` |
| `e28430f` (HEAD) | `exit=1` — `no tooltip carries the branch label` |

The tooltip inventory at Phase 1 contained `master` and
`scratch/scratch-branch-for-margain-testing-overflow`; at HEAD both are absent while the *name*
tooltip survives. The instrument was itself verified in both directions — its first version expected
the raw `refs/heads/…` ref rather than the stripped `branchLabel` and so failed on both trees for the
wrong reason; corrected, it passes on Phase 1 and fails on HEAD.

**What it breaks:** acceptance criterion 4, and step 1.3 in full — *"the tooltips are why truncation
is acceptable: the branch label appears nowhere else in the row, and the lock reason nowhere else in
the panel."* Also MADR 0049's Confirmation bullet *"a test that a truncated chip still exposes its
full label through a tooltip"*, which was never written.

**Why it happened:** History's chips self-tooltip inside `RefChip` (`ref_chip.dart:173-174`);
`LabelChip` does not. Deviation (a) moved the worktree tooltips from the call site into
`ChipEntry.tooltip`, which feeds only the `+N`.

**Decision** (maintainer: tooltip inside `LabelChip`). `LabelChip` wraps itself in a `MacosTooltip`,
matching `RefChip`. Chosen over tooltipping in `ChipStrip` (which would double-wrap History's already
self-tooltipping chips) and over restoring the per-chip tooltip at the worktrees call site (the second
implementation the extraction existed to remove — the next surface to adopt the strip would lose it
again). A chip that bounds itself must also explain itself, and putting both in one widget fixes all
seven `LabelChip` surfaces at once rather than only worktrees.

**Scope added to Phase 3** (the phase that touches the other surfaces): `lib/features/common/label_chip.dart`,
`lib/features/branches/branch_navigator.dart` — its existing outer tooltip on a `LabelChip`
(`:1664`, the nesting risk the plan's Risks section already named) is removed so the two do not nest —
a guard in `test/worktree_row_overflow_test.dart` that the probe above becomes, and a catalogue entry
`p1: a truncated chip cannot be read`. MADR amended at its Decision Outcome.

**Cost of doing nothing:** the row is bounded but illegible — truncation traded for unreachable text,
which is the outcome step 1.3 ruled out.

### Deviation (c) — a second, unbounded chip widget exists beside `LabelChip` (2026-09-13)

**First recorded wrongly, and corrected the same day.** The initial entry claimed `LabelChip` had
**seven** users besides `worktrees_view.dart`, from `grep -rln 'LabelChip' lib/`. That is a *substring*
match: `forge_widgets.dart`, `project_sections.dart`, `github_panel.dart` and `gitlab_panel.dart`
matched on `ForgeLabelChip` and `MiniLabelChip`, and none of the four imports `common/label_chip.dart`.
The maintainer's first scope answer ("all seven") was given on that bad premise and was re-asked once
the facts were right. Recorded rather than quietly amended: the grep that produced it is the same class
of mistake this repository's own notes warn about, and a corrected record is the point of the record.

**What is actually true**, from `grep -rn '\bLabelChip(' lib/` plus the import check:

| Widget | Files | Bounded? |
| --- | --- | --- |
| `LabelChip` | `worktrees_view.dart` (9 sites), `branch_navigator.dart` (5), `stash_view.dart` (1), `switcher/connection_switcher.dart` (1) | yes, since Phase 1 |
| `ForgeLabelChip`, `MiniLabelChip` | defined in `forge_widgets.dart`; used in `project_sections.dart` (3), `github_panel.dart` (1), `gitlab_panel.dart` (1) | **no** — bare `Container` + `Text`, no `maxWidth`, no ellipsis |

So MADR 0049 F8 named the right *files* for `LabelChip`. Two corrections to it stand: the switcher is
`lib/features/switcher/connection_switcher.dart`, not `lib/features/connections/`; and the site counts
were low (six→nine for worktrees, four→five for branches).

**The real finding is the second widget.** `ForgeLabelChip` and `MiniLabelChip` are `LabelChip`'s
pre-Phase-1 shape — unbounded — and their text is arbitrary remote input (GitHub/GitLab label names),
which is the unbounded-input case this MADR is about. Their exposure is narrower than the worktree
row's: all five sites sit in `Wrap`s (`forge_widgets.dart:368`, `project_sections.dart:396, 554`), and
a `Wrap` moves children to the next run rather than overflowing. What a `Wrap` cannot do is split a
**single** child, so one label longer than the pane still overflows.

**Decision** (maintainer). Phase 3 fixes the three `LabelChip` surfaces as planned, and additionally
**measures** the forge chips with a pathological single label — fixing them only if the measurement
shows an overflow, which is 3.2's own rule applied to a widget the MADR never counted. Bounding them
unmeasured was offered and declined: it would change forge rendering, and possibly goldens, for a
defect nobody has shown.

**Cost of doing nothing:** a known-unbounded chip widget in four files, fed by remote input, with no
measurement and no guard — the MADR would close claiming a class it had checked only half of.

### Phase 3 measurement — the answer to the MADR's open question (2026-09-13)

`test/label_chip_row_overflow_test.dart`, pathological fixtures at 240 pt, run **before** any Phase 3
change and again against the pre-plan tree (`8032c83`) to separate what this plan caused from what it
merely found:

| Surface | Pre-plan `8032c83` | HEAD `3eb35a9` | Verdict |
| --- | --- | --- | --- |
| Branch row — `branch_navigator.dart:1589` | overflow **181 px** | overflow **111 px** | still overflows |
| Section header — `section_collapse.dart:158` | overflow **12 px** | overflow **12 px** | independent defect |
| Stash row (long subject + long branch) | clean | clean | guard only |
| Switcher tile (long label, linked worktree) | clean | clean | guard only |
| `MiniLabelChip`, single over-long label in a `Wrap` | clean | clean | guard only |
| `ForgeLabelChip`, single over-long label in a `Wrap` | clean | clean | guard only |

> **The branch-row figures were first recorded as 181 px → 5 px, and that was wrong.** The fixture
> keyed `branchForgeProvider` and `mergedBranchesProvider` on the full ref (`refs/heads/feature/…`)
> while the row looks both up by `GitRef.shortName`, so the *merged* and *request* chips never
> rendered and the "pathological" row carried a single chip. The mistake surfaced only because a
> sabotage passed when it should have failed — raising the cap to 99 changed nothing, which it could
> not have done had the row held three chips. Re-keyed, the same fixture overflows by **111 px**. The
> corrected numbers are in the table; the retracted ones are named here rather than quietly replaced.

**Three findings, and two of them are "not broken".**

1. **Phase 1 helped branches without touching them.** Bounding `LabelChip` cut that row's overflow from
   181 px to 111 px — the chip bound travelling to every surface, which is what MADR 0049's
   Consequences predicted. It was not enough: two chips at `LabelChip.defaultMaxWidth` are 320 pt in a
   212 pt row, so the residual is the row's own layout, not the chip's.
2. **The forge chips are unbounded and still do not overflow.** A `Wrap` hands its child its own
   maximum width, so an over-long label soft-wraps to a second line rather than painting outside its
   bounds. Unbounded in a `Row` is a defect; unbounded in a `Wrap` is merely ugly at the extreme. This
   is precisely why deviation (c) chose to measure rather than bound them — the alternative would have
   changed forge rendering, and possibly goldens, for a defect that does not exist.
3. **Stash and switcher were never broken.** Both bound their subject already (`maxLines` + ellipsis on
   the stash subject, `Expanded` + ellipsis on the switcher name), and both chips are fixed short
   strings. Their tests stand as regression guards. Recorded as findings, per 3.2 — "not broken" is an
   answer, not a gap.

This replaces MADR 0049's **"Not established"** paragraph: the class is now measured across every chip
surface in the app, and exactly one other row overflows.

### Deviation (d) — the branch row, and a shared header outside the plan's file list (2026-09-13)

**Found** by the measurement above. Both are **pre-existing**: reproduced against the unmodified
pre-plan tree at `8032c83` in a detached scratch worktree, not against a tree this plan had touched.

**(d.1) The branch row, 5 px.** In scope — 3.2 already says a surface that overflows is fixed in this
phase. **Decision** (maintainer): fix it by adopting the shared `ChipStrip`, as worktrees did, rather
than by the narrower Phase 1 pattern. The row's badges — checked-out-elsewhere, merged, PR/MR,
divergence — become a capped strip with `chipsMayShrink`, so the branch name flexes and the remainder
collapses into `+N`. Chosen because the alternative leaves Branches with a different solution from
Worktrees, which is the second implementation deviation (a) existed to remove; and because it kills the
class rather than the five pixels.

**(d.2) `lib/features/common/section_collapse.dart` — a file this plan does not list.**
`CollapsibleSectionHeader` builds `titleCluster` as a min-sized `Row` around a bare, unbounded
`Text(title)`, then places it beside a `Spacer` and its trailing buttons (`:122-170`). At 240 pt that
overflows by 12 px. It is **not** a `LabelChip` row and it is untouched by every commit in this plan —
its 12 px is identical before and after — so it is a defect this work uncovered, not one it caused.

**Decision** (maintainer): add the file to Phase 3's scope and fix it here. The title cluster becomes
flexible and the title ellipsizes, with a guard at 240 pt. One file; `CollapsibleSectionHeader` is
shared by Branches and Forge (the section-collapse canon is deliberately one header for both), so the
single fix covers both surfaces.

**Cost of doing nothing** was stated and declined: Phase 2's clip now *contains* this overflow, so the
header would be silently truncated at the divider instead of painting across it — containment, not
repair, and exactly the "a clip can hide a new layout bug from a human eye" consequence the MADR
warned about.

**Scope added to Phase 3:** `lib/features/branches/branch_navigator.dart`,
`lib/features/common/section_collapse.dart`, and their guards in
`test/label_chip_row_overflow_test.dart`. Catalogue entries follow in Phase 4.

### Phase 3, executed (2026-09-13)

Commit `f846469` (code). Gate: `dart format` clean on all nine files, `flutter analyze` **No issues
found**, full suite **`03:33 +4110 ~3`** — the 48 workspace goldens among them, unshifted.

**Deviation (b) — the chip explains itself.** `LabelChip` gained a `tooltip` (defaulting to its own
text) and wraps itself in a `MacosTooltip`. `branch_navigator.dart`'s three outer tooltips were
un-nested by passing their richer messages through the new parameter rather than deleting them, so no
hover text was lost. A `labelChipEntry` helper builds the chip and its `ChipEntry` from one string,
because the tooltip reaches the reader by two routes — the visible chip's hover and the `+N` list —
and writing it twice is how the two drift.

**And the `+N` chip had the same disease.** Once chips self-tooltipped, `ChipStrip`'s wrapper put two
tooltips on the `+N`; `chip_strip_test` failed with `Bad state: Too many elements`, which is the test
noticing before a person could. `overflowChipBuilder` now takes `(hidden, hiddenTooltip)` and the strip
wraps nothing — History's `_RefChipChrome`, which has no tooltip of its own, adds the wrapper at its
own call site.

**Deviation (d.1) — the branch row.** Adopted `ChipStrip`, and the first attempt was wrong in a way
worth recording. It used the strip's **default** (intrinsic) mode on the reasoning that the branch row
is History's shape — right-aligned past a `Spacer` — where a flex chip can collapse to zero. Measured,
that does not bound the row: one chip may be `LabelChip.defaultMaxWidth` wide, so two of them are
320 pt in a 212 pt row.

| Branch-row variant at 240 pt | Overflow |
| --- | --- |
| Intrinsic strip, `maxVisible: 2` | 111 px |
| Intrinsic strip, `maxVisible: 1` | 33 px |
| Flexible strip, `chipsMayShrink: true` | **none** |

So **capping alone cannot bound a row whose chips are individually capped too wide** — the strip must
also give way. The `Spacer` stays, so the badges remain right-aligned; that is safe only because the
row's non-flexible parts (the icon, the reserved CI width) are small enough to leave real free space
for the flex children. The CI glyph moved out of the strip into `_ciBadge` — it is not a chip, never
truncates, and collapsing the one badge that changes while the user watches into a `+N` would be a
regression.

**Deviation (d.2) — the section header, fixed twice.** Making the title cluster `Flexible` with an
ellipsizing title moved the overflow one `Row` inward instead of removing it:
`forge_project_sections_test` then failed with 45 px at `section_collapse.dart:122`, because the
cluster's `count` and `caption` still held their intrinsic width. Both now flex and ellipsize.

**The guards, each seen to fail** in a detached scratch worktree against the final code:

| Sabotage | Caught by | Failure |
| --- | --- | --- |
| `LabelChip` stops tooltipping | both tooltip guards | `Expected: contains 'Branch: scratch/…'` |
| the section title cluster is intrinsic again | branch row guard | `RenderFlex overflowed by 12 pixels` |
| the branch chips stop giving way | branch row guard | `RenderFlex overflowed by 60 pixels` |
| the branch strip holds its intrinsic width | branch row guard | `RenderFlex overflowed by 111 pixels` |
| the branch chips get no width to shrink into | **the width guard alone** | `Expected: a value greater than <8>` |

The last row is the one that matters most. Collapsing the chips to zero width *contains* the row
perfectly — the overflow guard passes — and produces a branch row with no badges at all, which is
precisely the failure History's strip records. Only `a branch badge still has width at 240 pt` sees it,
which is why `chipsMayShrink` is defensible here rather than merely convenient.

**Two mistakes of mine, caught by the instruments rather than by review.** The branch fixture keyed its
providers by the full ref instead of `shortName`, so it measured a one-chip row — exposed by a sabotage
that passed. And the fixture's absolute paths named a home account, which
`no_real_identifiers_scan_test` failed on; they are now `/Users/<user>/…`. Both are recorded because a
measurement is only worth what its fixture is.

**Not done, deliberately:** the forge chips. `ForgeLabelChip` and `MiniLabelChip` remain unbounded, and
the measurement is why — a `Wrap` hands its child its own maximum width, so an over-long label
soft-wraps rather than overflowing. Their tests stand as guards against a future caller moving them
into a `Row`.

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
