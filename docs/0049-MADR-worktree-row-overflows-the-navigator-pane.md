---
status: "proposed"
date: 2026-09-12
decision-makers: [Maintainer]
consulted: []
informed: [Magic Git contributors]
verified: 2026-09-12
---

# A worktree row paints into the next pane: two unbounded children in one `Row`, and a pane that constrains layout without clipping

## Context and Problem Statement

With a long-named worktree in the list, the Worktrees overview row's **name and branch chip cross the
navigator/canvas divider and paint over the detail pane**. The path line directly beneath them
ellipsizes correctly, which is the clue: the row is not too narrow — parts of it are bounded and parts
are not.

This record is the analysis. It proposes what to change and how to prove it; no code is changed by it.

### F1 — What was seen

Reported from the running build, and confirmed on screen: the Worktrees page with two worktrees, the
second named `magic-git-scratch-scratch-branch-for-margain-testing-overflow` on branch
`scratch/scratch-branch-for-margain-testing-overflow`. Its name and its blue branch chip run past the
list pane's divider and over the "Select a worktree to inspect…" panel. The grey path line under the
name is cut with an ellipsis, as intended.

### F2 — Reproduced deterministically, away from the tree

In a detached scratch worktree, the reported case was reproduced as a widget test that pumps the real
`WorktreesView` with those two worktrees:

```text
Expected: null
  Actual: FlutterError:<A RenderFlex overflowed by 944 pixels on the right.>
```

The magnitude is inflated — Flutter's test font is wider than the real one — so the number pins the
**mechanism**, not the visual size. F1 is the evidence for how it looks.

### F3 — The mechanism

`lib/features/worktrees/worktrees_view.dart:1058-1130` builds each row as:

```dart
Row(children: [
  MacosIcon(...), const SizedBox(width: 10),
  Expanded(child: Column(children: [
    Row(children: [                       // ← nothing in here is flexible
      Text(wt.name, ...),                 // ← no maxLines, no overflow
      LabelChip(wt.branchLabel, ...),     // ← intrinsic width, always
      ...up to four more chips...
    ]),
    Text(wt.path, maxLines: 1, overflow: TextOverflow.ellipsis, ...),  // ← correct
  ])),
])
```

The outer `Expanded` bounds the **Column** to the pane, which is why the path line ellipsizes. The
**inner** `Row` has no flexible child, so it lays out at its children's intrinsic widths and exceeds
the constraint it was given. `Flex` paints an overflowing child *outside* its own bounds —
`clipBehavior` defaults to `Clip.none` — and a release build draws no debug stripe overlay, so the
defect reads as text spilling rather than as an error.

### F4 — Two independent causes, measured

Each candidate was applied alone to a scratch copy and the same reproduction re-run:

| Change | Result |
| --- | --- |
| *(none — as shipped)* | overflowed by **944 px** |
| name → `Flexible` + `maxLines: 1` + ellipsis | overflowed by **147 px** |
| `LabelChip` → `maxWidth: 180` + `Flexible` + ellipsis | overflowed by **551 px** |
| **both** | **no overflow** |

Neither change alone is sufficient. That matters: fixing only the name would have looked right on a
moderately long name and failed again on a long branch.

### F5 — The chip has no bound at all, and the app already knows better

`LabelChip` (`lib/features/common/label_chip.dart:19-40`) is a `Container` → `Row(mainAxisSize: min)`
→ plain `Text`: no maximum width, no `maxLines`, no ellipsis. Its width is whatever its label is.

History solved exactly this class for its ref chips:

* `RefChip` caps its own width and ellipsizes inside it (`ref_chip.dart:202-216, 253-256`);
* `RefChipStrip` shows at most `maxVisible` chips and collapses the rest into a `+N` chip
  (`ref_chip.dart:125-140`);
* and the code carries the trap in a comment: do **not** wrap those chips in `Flexible` inside a
  min-sized strip, because a flex child there can collapse to zero width — "the history pop-out showed
  subjects with no badges at all".

Branches does the row half correctly too: its name is `Flexible` + `maxLines: 1` + ellipsis
(`branch_navigator.dart:1600-1610`). The worktree row is the outlier, not the norm.

### F6 — The pane constrains layout but never clips

`ResizablePanePair` lays the navigator out as `SizedBox(width: visibleExtent, child: leading)` beside
`Expanded(child: trailing)` (`lib/features/common/resizable_master_detail.dart:145-151`). A `SizedBox`
bounds **layout**, not painting, so anything that overflows inside the navigator paints across the
divider and onto the canvas.

This is why the failure presents as *spilling into the main panel* rather than being cut off at the
divider — and it is not specific to worktrees: every navigator pane in the app (Repository, Branches,
Stashes, Forge, Worktrees) shares this scaffold.

The pane is user-resizable between **240** and **720** points, default **320**
(`repository_workspace_prefs.dart:167-169`), so there is no width at which long names are safe.

### F7 — Why no test caught it

`test/worktrees_view_test.dart` builds its fixtures with `git worktree add` under the names `app`,
`app-feature` and `app-gone` — all short. Nothing in the suite renders a long one.

A `RenderFlex` overflow is thrown as an exception in widget tests, so guarding this costs one line —
and History already does exactly that:

```dart
// A RenderFlex overflow is reported as a test exception, so this fails
// loudly on the regression rather than merely looking wrong.
expect(tester.takeException(), isNull);
```

(`test/history_ref_chip_overflow_test.dart:250-258`.) No equivalent exists for Worktrees, Branches,
Stashes or the connection switcher.

### F8 — Blast radius

`LabelChip` is used in `worktrees_view.dart` (six sites), `branch_navigator.dart` (four),
`stash_view.dart` and `connection_switcher.dart`. Branches absorbs pressure through its flexible name;
the others have the same exposure as the worktree row.

With both changes applied in the scratch copy, the **full suite passed: `+4085`, zero failures** — so
nothing in the suite depends on chips being unbounded.

## Decision Drivers

* The row must stay readable at the **minimum** pane width (240), not merely at the default.
* No pane may paint over another. A layout bug anywhere should degrade to truncation, not to a
  scribble on the neighbouring pane.
* Whatever is truncated must stay reachable — the full value already exists in the detail pane, and a
  tooltip is the established way to carry the rest.
* The app already has a solved instance of this problem; a second, different solution would be a
  second thing to maintain.
* The guard must fail on the regression by itself, without a human looking at a screenshot.

## Considered Options

* **A — Bound the row and the chip**: the worktree name becomes `Flexible` + ellipsis, and `LabelChip`
  gains a maximum width and ellipsizes inside it.
* **B — Bound only the row's name.**
* **C — Adopt History's strip**: cap the chips shown per row and collapse the rest into `+N`.
* **D — Clip the navigator pane** (`ClipRect` in `ResizablePanePair`).
* **E — Let the chips wrap** onto a second line (`Wrap`).

## Decision Outcome

Chosen option: **"A — bound the row and the chip", together with "D — clip the navigator pane"**, and a
guard in History's style.

A is the measured minimum that removes the defect (F4), and it fixes the class rather than this row:
`LabelChip` is shared by four features, and bounding it there fixes every user of it at once. D is not
a fix — it repairs nothing — but it converts *any* future overflow, anywhere in any navigator, from
"paints over the next pane" into "is cut off at the divider", which is the difference between a
cosmetic truncation and a display that lies about which pane it belongs to.

C is deliberately **not** taken now: it is the right answer when a row carries *many* chips, which the
worktree row can (branch, main, open, locked-with-reason, missing). If A leaves rows looking crowded
at 240 points, C is the follow-on, and History's `RefChipStrip` is the implementation to copy — along
with its warning about `Flexible` inside a min-sized strip.

The truncated name and chip must carry a `MacosTooltip` with the full text, following
`branch_navigator.dart`'s use of tooltips on its chips.

### Consequences

* Good, because the reported defect goes away at every pane width, by the measured minimum change.
* Good, because `LabelChip` stops being an unbounded-width widget in four features at once.
* Good, because D bounds the damage of any overflow the app grows later, including ones nobody has
  written a guard for.
* Neutral, because names and chips will visibly truncate at narrow widths; the detail pane still shows
  the full path, and tooltips carry the rest.
* Bad, because a clip can hide a *new* layout bug from a human eye — it is deliberate containment, and
  the guard tests, not the clip, are what keep overflow from being silently normal.

### Confirmation

* A guard test for the Worktrees overview that pumps the pathological worktree — long name, long
  branch, locked with a reason, prunable — at the **minimum** pane width (240) and asserts
  `expect(tester.takeException(), isNull)`. Run first against the unchanged tree, where it must report
  `A RenderFlex overflowed by …`, exactly as the reproduction in F2 did.
* The same guard for the Branches, Stashes and switcher rows that use `LabelChip`.
* A test that a truncated chip still exposes its full label through a tooltip.
* The full suite, which passed under the candidate fix in scratch (F8) and must pass again.
* Manually, in the running app: the reported worktree row at the default width and dragged to minimum,
  with nothing crossing the divider.

## Pros and Cons of the Options

### A — Bound the row and the chip

* Good, because it is measured: both halves are needed, and together they remove the overflow (F4).
* Good, because the chip fix lands in one shared widget rather than at six call sites.
* Good, because it matches what Branches and History already do.
* Bad, because a maximum chip width is a magic number; 180 was enough in the reproduction, and the
  plan should justify whatever value ships against the 240-point minimum pane.

### B — Bound only the row's name

* Good, because it is the single smallest edit.
* Bad, because it is **measurably insufficient**: 147 px of overflow remained (F4). It would have
  looked fixed against a short branch name and failed again on a long one.

### C — History's capped strip with `+N`

* Good, because it is the proven answer for rows that carry many chips, already in this codebase.
* Good, because it keeps the name legible no matter how many states a worktree is in.
* Neutral, because it is more machinery than the reported defect needs today.
* Bad, because adopting it without A still leaves an unbounded name and an unbounded chip — the strip
  caps how many chips appear, not how wide one chip can be.

### D — Clip the navigator pane

* Good, because it contains every overflow in every navigator, present and future, in one place.
* Good, because it is two lines in the shared scaffold.
* Bad, because alone it fixes nothing: the row would still be wrong, merely amputated at the divider.
* Bad, because it removes the visual symptom that made this defect reportable at all — which is why it
  is paired with guards rather than shipped on its own.

### E — Wrap the chips onto a second line

* Good, because nothing truncates: every chip stays fully readable.
* Neutral, because unlike History's list, the Worktrees overview has no fixed row extent, so variable
  heights are *possible* here.
* Bad, because row heights would vary with branch-name length, which the keyboard navigation and
  `ensureRowVisible` scrolling treat as uniform, and a two-line row in a 240-point pane pushes the
  path line out of view.

## More Information

* **Code this record reads.** `lib/features/worktrees/worktrees_view.dart:1058-1130` (the row);
  `lib/features/common/label_chip.dart:19-40`; `lib/features/common/resizable_master_detail.dart:145-151`
  (the unclipped pane); `lib/features/common/adaptive_workspace_layout.dart:200-232` (navigator sizing);
  `lib/core/settings/repository_workspace_prefs.dart:167-169` (240 / 320 / 720);
  `lib/features/history/ref_chip.dart:125-140, 202-216, 253-256` (the solved instance);
  `lib/features/branches/branch_navigator.dart:1600-1610` (a correctly bounded name).
* **Evidence.** The live screen (F1); the scratch reproduction and the three candidate measurements
  (F2, F4), run in a detached worktree and removed afterwards — the working tree was never dirtied.
* **Not established.** Whether any other pane in the app currently overflows: only the Worktrees row
  was reproduced. F6 says every navigator *can*, not that any other does. The plan should run the same
  pathological fixtures through the Branches, Stashes and switcher rows before claiming the class is
  closed.
* **No implementation exists.** This record proposes a decision; a plan follows only on approval.
