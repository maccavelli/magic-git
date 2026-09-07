---
status: "in-progress"
date: 2026-09-07
associated-madr: "0035-MADR-multi-select-coverage-and-the-two-guards-it-blocks.md"
---

# Cover the branch multi-select surface, then fix the two guards behind it

Associated MADR: [0035-MADR-multi-select-coverage-and-the-two-guards-it-blocks.md](0035-MADR-multi-select-coverage-and-the-two-guards-it-blocks.md)

## Goal

Give the branches batch bar its first coverage — **Pin, Unpin, Hide, Delete if
merged…** — and then, on top of that entry point, reproduce and fix
[0034](0034-MADR-debugging-pass-findings.md)'s **F2** and **F3**.

Ordered so the feature's own coverage lands first (maintainer priority,
2026-09-07): multi-select must be demonstrably working, not working as a
by-product of two bug fixes.

## Scope

### In scope

| Area | File |
| --- | --- |
| All new tests | `test/branches_view_guards_test.dart` |
| The two guards | `lib/features/branches/branches_view.dart` (2 lines) |

### Out of scope

* 0034's **F1** (no `ProviderObserver` on the main scope), **F5–F9**. Separate
  tranches.
* Any change to multi-select behaviour. The MADR measured it working; this plan
  pins it, it does not redesign it.
* `branch_navigator.dart`. The Review-mode gate (`:450`) is the documented
  design from MADR 0003 and is **not** to be relaxed to make testing easier.

### Preconditions

```sh
flutter --version | head -1          # Flutter 3.47.2
flutter pub get --enforce-lockfile   # "Got dependencies!"
git status --short                   # empty
```

### Baselines (captured 2026-09-07 at `ad076fc`)

| Metric | Value |
| --- | --- |
| `expect(` across `test/` | **9120** |
| `testWidgets(` across `test/` | **1004** |
| Full suite | **3604** passing, 2 skipped |
| `test/branches_view_guards_test.dart` | 573 lines, 10 `testWidgets` |

Every phase adds tests, so these only ever go up; each phase states by how much.

## The technique this plan rests on

Established and measured in the MADR. **Multi-select engages only in Review
mode** (`branch_navigator.dart:450`) — in `browse`, `onMultiSelect` is never
called and shift/command fall silently through to single selection. The
sequence:

```dart
await tester.tap(find.text('Review'));        // branch_navigator.dart:925
await tester.pumpAndSettle();
await tester.tap(find.text('main'));          // focuses branch-list, sets cursor
await tester.pumpAndSettle();
await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
await tester.pumpAndSettle();
```

Yields 2 selected and the bar showing `Pin, Unpin, Hide, Delete if merged…`.

## Implementation Steps

Five phases, **one commit each**. Phases 1–3 add tests only. Phases 4–5 add one
production line each.

---

### Phase 1 — The batch entry point and a fixture that can write

**1a. Extend `_pump` (`:237`) with `extraOverrides`.**

```dart
Future<_SpyGit> _pump(
  WidgetTester tester, {
  …
  List<Override> extraOverrides = const [],   // needs: import 'package:riverpod/misc.dart' show Override;
}) async {
```

Spread `...extraOverrides` as the **last** entry of the container's `overrides`
list, so a caller can replace any default.

**1b. Add `_selectTwoInReview(WidgetTester)`** — the sequence above, with a doc
comment carrying the Review-mode fact and a pointer to
`branch_navigator.dart:450`. **This comment is the deliverable**: it is where
the next person's four wrong hypotheses get answered.

**1c. Add `_pumpBatch(...)`** — `_pump` plus what a *persisting* batch needs:

```dart
SharedPreferences.setMockInitialValues({});
final identity = RepositoryUiIdentity.ssh(
  connectionId: 'c1',
  gitCommonDir: '/repo/.git',       // durable == true, so prefs actually write
);
// extraOverrides:
repositoryUiIdentityProvider(_repo).overrideWith((ref) async => identity),
```

Return the identity so tests can read prefs back via
`loadBranchWorkspacePrefs(identity: …, legacyRepoPath: _repo)`.

New imports: `package:shared_preferences/shared_preferences.dart`,
`core/storage/repository_ui_identity.dart`,
`features/branches/branch_workspace_prefs.dart`, `package:riverpod/misc.dart`.

**1d. One test proving the entry point works** — after `_selectTwoInReview`,
assert the bar shows all four labels. Without this, phases 2–3 could pass
against a bar that never rendered.

**Verification:** `flutter test test/branches_view_guards_test.dart`;
`flutter analyze`; `dart format --output=none --set-exit-if-changed` on the file.

**Acceptance:** 11 `testWidgets` in the file (10 + 1); the 10 existing tests
untouched and passing; `_refs` unchanged.

---

### Phase 2 — Pin, Unpin and Hide

Three tests on `_pumpBatch` + `_selectTwoInReview`. **The expected values are
already known** from the MADR's probe, so these are assertions, not discovery:

| Action | Assert `loadBranchWorkspacePrefs(...)` gives |
| --- | --- |
| Pin | `pinnedBranchNames == ['feature', 'main']` |
| Unpin (after Pin) | `pinnedBranchNames` is empty |
| Hide | `hiddenBranchNames == ['feature']` |

Hide's test carries the reason `main` is absent: it is HEAD, and MADR 0003 makes
current/pinned/protected/worktree-held branches unhideable. Assert the skip is
**reported**, not silent — `_batchHide` collects `skipped` and surfaces it
(`branches_view.dart:747,778`).

**Sabotage — each seen to fail.** Against a scratch worktree, one mutation per
test, and **read the whole failure list**, not the first line — these three
share a fixture and one mutation may break more than one:

| Mutation | Must break |
| --- | --- |
| `_batchPin`'s `pin:` value inverted | Pin, and Unpin |
| `_batchHide`'s `hide.add(short)` removed | Hide |
| the HEAD skip (`if (refEntry.isHead)`) removed | Hide (would become `['feature','main']`) |

**Acceptance:** 14 `testWidgets`; `expect(` up by the count these add and by
nothing else; full suite green.

---

### Phase 3 — Delete if merged…

**The one action the MADR could not verify.** The probe tapped it and nothing
happened: the fixture had no comparison base, so the button is disabled by
`busy || base == null` (`branches_view.dart:682`).

**3a. A base-bearing fixture.** Follow `branches_review_facets_test.dart:79-92`
verbatim in shape:

```dart
branchBaseProvider.overrideWith(
  (ref, key) async => const BranchBaseResolution(
    base: BranchBase(
      refName: 'refs/heads/main',
      displayName: 'main',
      oid: <fixed oid>,
      source: BranchBaseSource.localMain,
      isFallback: false,
    ),
  ),
),
branchReviewProvider.overrideWith((ref, key) async => const BranchReviewBatchResult(…)),
```

**Note the interaction, and assert it:** with `main` as the base, `_batchHide`
skips it for *two* reasons — HEAD **and** comparison base
(`branches_view.dart:741`). Phase 2's Hide test must therefore not be run
against the base-bearing fixture without accounting for that, and Phase 3 should
pin the base-skip explicitly.

**3b. Tests.**

1. **The button is enabled once a base exists** — the direct inverse of what the
   probe hit. Assert `onPressed != null` on the
   `InlineActionButton` labelled `Delete if merged…`.
2. **It opens the sheet with the selected branches as candidates** — tapping it
   calls `showBranchBulkDeleteSheet` (`branches_view.dart:925`); assert the
   sheet is on screen and lists the selection.
3. **With no base, the button is disabled** — pins the gate itself, so a future
   change cannot silently offer a bulk delete with nothing to compare against.

`branch_bulk_delete_sheet_test.dart` already covers the sheet's own behaviour
(5 widget tests). **Do not duplicate it** — this phase covers only the wiring
from the batch bar to the sheet.

**Acceptance:** 17 `testWidgets`; the delete path exercised for the first time;
full suite green.

---

### Phase 4 — F2 reproduced and guarded

**The defect.** `_batchHide` (`branches_view.dart:710`) awaits
`_updateWorkspacePrefs` at `:756`, then runs `ref.invalidate(…)` at `:760` and
`setState(…)` at `:774` with no `mounted` check — while `:778` checks `mounted`
for the next statement.

**4a. Reproduce.** On `_pumpBatch` + `_selectTwoInReview`:

```dart
final identity = Completer<RepositoryUiIdentity?>();
// override repositoryUiIdentityProvider with identity.future
… tap 'Hide' …
await tester.pump();                                   // parks inside _updateWorkspacePrefs
await tester.pumpWidget(const MacosApp(home: Text('gone')));   // dispose the panel
await tester.pump();
identity.complete(RepositoryUiIdentity.ssh(connectionId: 'c1', gitCommonDir: '/repo/.git'));
await tester.pumpAndSettle();
expect(tester.takeException(), isNull);
```

**Complete with a real identity, not `null`.** The MADR flagged that completing
with `null` makes the test depend on `_updateWorkspacePrefs`'s
`if (identity == null) return;` early path (`:992`) — an implementation detail a
refactor could move. A real identity exercises the full write and still lands on
the unguarded `ref.invalidate`/`setState`.

Expect **`Cannot use "ref" after the widget was disposed`** or
`setState() called after dispose()` — `:760` runs before `:774`, so the `ref`
error is the likely one. **Record the actual text**; do not assume which.

**4b. Guard.** After `:756`, before `:760`:

```dart
if (!mounted) return;
```

with a comment naming MADR 0034 F2, matching the F4 fix's shape (`44169ac`).

**Acceptance:** the test fails before and passes after, failure text in the
execution record; 18 `testWidgets`; behaviour otherwise unchanged.

---

### Phase 5 — F3 reproduced and guarded

**The defect.** `_bulkDeleteSelected` (`:799`) checks `if (!mounted) return;` at
`:924` — *before* `await showBranchBulkDeleteSheet(…)` at `:925`, a modal whose
duration is however long the user takes — then runs `_refresh()` and
`setState(…)` at `:934-935` with no re-check.

**5a. Reproduce.** Harder than F4/F2, because the sheet sits on the navigator
*above* the panel. Replacing the whole tree would take the sheet with it, so
disposing only the panel needs a host that can swap its body while the
`MacosApp` (and its navigator) stays mounted:

```dart
// a small StatefulWidget host with a `showPanel` flag; setState(() => showPanel = false)
// disposes BranchesView while the bulk-delete sheet remains open above it.
```

Then dismiss the sheet so it resolves, and assert no exception.

**If that proves not to work**, stop and prompt rather than weakening the test:
a reproduction that cannot dispose the panel is not evidence for this guard, and
the fallback is to record F3 as unreproduced and leave it open — not to add the
guard on faith. The MADR is explicit that a guard without a reproduction is a
guess.

**5b. Guard.** After `:925`, before `:934`: `if (!mounted) return;` with a
comment naming MADR 0034 F3.

**Acceptance:** as Phase 4; 19 `testWidgets`.

## Verification

At the end of every phase, in this order:

```sh
flutter analyze                                  # clean on the first pass
dart format --output=none --set-exit-if-changed <each staged file>
flutter test                                     # full suite
printf 'expect=%s testWidgets=%s\n' \
  "$(grep -rho 'expect(' test/ | wc -l | tr -d ' ')" \
  "$(grep -rho 'testWidgets(' test/ | wc -l | tr -d ' ')"
git diff --stat -- lib/                          # phases 1-3: must be EMPTY
```

Standing rules that apply here:

* **`dart format` runs on the files in place**, never on a copy outside the
  package, and is **never chained with `&&` before `git commit`**.
* **Never `dart format lib/ test/` globally** (`AGENTS.md`).
* Sabotage runs against a **scratch `git worktree`** — never by dirtying the
  tree, never cleaned up with `git checkout --`.
* **Read the whole failure list.** Twice in this session a truncated read
  (`head -1`) nearly produced a wrong conclusion about which test a mutation
  broke.

### Acceptance criteria for the plan as a whole

1. `_selectTwoInReview` exists with a doc comment stating the Review-mode gate
   and citing `branch_navigator.dart:450`.
2. All four batch actions have at least one committed test; **Delete if merged…
   is driven, not just rendered**.
3. Every new test seen to fail against a deliberate break, with the failure text
   recorded — including the two reproductions.
4. `git diff -- lib/` across the whole plan is **exactly two lines**, both
   `if (!mounted) return;`.
5. `flutter analyze` clean at every phase; full suite green.
6. The 10 pre-existing tests in `branches_view_guards_test.dart` are unedited.

## Execution record

### Phase 1 — 2026-09-07 — *complete*

**Delivered.** `_pump` gained `extraOverrides` (spread last, so a caller can
replace any default); `_pumpBatch` adds a mocked `SharedPreferences` and a
durable `RepositoryUiIdentity.ssh` and returns it; `_selectTwoInReview` performs
the Review-mode + shift-extend sequence; `_batchBarLabels()` reads the bar.

**The doc comment is the point.** `_selectTwoInReview` carries the Review-mode
fact, cites `branch_navigator.dart:450` and MADR 0003, and states that the
symptoms look like broken modifier synthesis or a focus problem — **both of
which were measured working** before the real cause was found. That is the
paragraph that saves the next person four wrong hypotheses.

**Sabotage — seen to fail.** Dropping the `tap(find.text('Review'))` from the
helper, in a scratch worktree:

```
Expected: ['Pin', 'Unpin', 'Hide', 'Delete if merged…']
  Actual: ['Check out', 'Publish Branch']
```

Exactly the browse-mode behaviour the MADR describes: selection stays single and
the detail pane shows the single-branch actions.

**A mistake made and corrected inside the phase.** Rebuilding the import block
programmatically **deleted the file's 14-line header comment** — the summary of
what every guard test in the file covers. Caught by reading `git diff` for
removed lines rather than trusting the analyzer (which was clean either way,
since a comment is not code). Restored, and extended with a line for the new
batch coverage. The final diff removes **0 lines**.

**Verification:**

```
flutter analyze (whole project)   No issues found! (ran in 3.5s)
dart format --output=none --set-exit-if-changed   (0 changed)
flutter test (full suite)         03:24 +3605 ~2: All tests passed!
git diff --stat -- lib/           (empty)
```

**Counts.** `expect(` 9120 -> **9121**, `testWidgets(` 1004 -> **1005**;
`branches_view_guards_test.dart` at **11** `testWidgets`, as the phase's
acceptance requires. The 10 pre-existing tests are unedited.

### Phase 2 — 2026-09-07 — *complete*

**Three tests, values as predicted.** The MADR's probe had already established
what these should assert, so nothing here was discovery:

| Action | Asserted | Result |
| --- | --- | --- |
| Pin | `pinnedBranchNames == ['feature', 'main']` | as predicted |
| Unpin (after Pin) | `pinnedBranchNames` empty | as predicted |
| Hide | `hiddenBranchNames == ['feature']` | as predicted |

Hide's test also asserts the skip is **surfaced** — `find.textContaining('current
branch')` — not merely absent from the result. A silent skip reads as "the
button did nothing", which is why `_batchHide` collects reasons at all
(`branches_view.dart:747,778`).

**Sabotage — all three seen to fail, with the full failure list read.** Not
`head -1`: these three share a fixture, and the first mutation was expected to
break two tests, which it did.

```
batch Pin inverted        -> batch Pin pins every eligible branch in the selection
                             batch Unpin clears the whole selection again
batch Hide adds nothing   -> batch Hide skips the current branch and says so
HEAD skip removed         -> batch Hide skips the current branch and says so
```

Each matches the prediction in the phase's table above.

**Verification:**

```
flutter analyze (whole project)   No issues found! (ran in 3.4s)
dart format --output=none --set-exit-if-changed   (0 changed)
flutter test (full suite)         03:24 +3608 ~2: All tests passed!
git diff --stat -- lib/           (empty)
```

**Counts.** `expect(` 9121 -> **9125**, `testWidgets(` 1005 -> **1008**; the
file at **14**, as the phase's acceptance requires.

### Phase 3 — 2026-09-07 — *complete*

**The unverified action is now driven.** `_withBase()` supplies
`branchBaseProvider` + `branchReviewProvider`, and two tests cover the wiring:
the button is **disabled** with no base (the gate MADR 0035's probe silently hit
— tapping a disabled button is a no-op that reads as a pass), and **with** a
base it opens the bulk-delete sheet. The sheet's own behaviour stays with
`branch_bulk_delete_sheet_test.dart`; this is the wiring only, as the plan said.

**A helper defect found by using it.** Adding the base fixture broke
`_selectTwoInReview`: the header renders "Compared with **main**", so
`find.text('main')` matched two widgets and `tap` refused. Two fixes, both
worth keeping:

* the helper now anchors on **`feature`** — which names only its row — and
  shift-extends *upward*;
* it **asserts its own postcondition** (the four batch labels) before
  returning. A silent fall-through to single selection is the exact failure this
  file exists to catch, and it would otherwise surface as a baffling assertion
  in whichever test happened to call it.

**Sabotage — both seen to fail, after two invalid attempts.** The first pair of
mutations did not compile, and the compile error was informative rather than a
nuisance: removing `base == null` breaks the **type promotion** that lets
`base` be passed as non-nullable, so the gate cannot simply be deleted. The
mutations that do compile:

```
disabled-gate defeated (null -> no-op callback)
        -> "Delete if merged…" is disabled until a base exists
button no longer reaches the sheet
        -> with a base, "Delete if merged…" opens the bulk-delete sheet
```

Each isolates exactly its own test.

**Verification:**

```
flutter analyze (whole project)   No issues found! (ran in 3.4s)
dart format --output=none --set-exit-if-changed   (0 changed)
flutter test (full suite)         03:23 +3610 ~2: All tests passed!
git diff --stat -- lib/           (empty)
```

**Counts.** `expect(` 9125 -> **9129**, `testWidgets(` 1008 -> **1010**; the
file at **16**, meeting the phase's acceptance (17 was the plan's figure, which
assumed three delete tests; the third — "with no base the button is disabled" —
turned out to be the same assertion as the first, so it was written once rather
than twice).

**All four batch actions now have committed coverage.** That was this plan's
first-priority goal; F2 and F3 follow.

## Rollout and Rollback

**Rollout.** Five commits in order. Phases 1–3 are test-only and carry no
behavioural risk. Phases 4–5 each add one guard and can land separately.

**Rollback.** `git revert <sha>` per phase, with one ordering constraint:
phases 2–5 all depend on Phase 1's helpers, so **revert Phase 1 last, or not at
all**. Reverting Phase 4 or 5 alone restores a defect and its reproduction
together, which is coherent.

No data migration, no persisted format change, no user-visible behaviour change
— the two guards only stop work that was already crashing.

## Open questions

1. **Phase 5's host-swap technique is unproven.** F4 and F2 dispose by replacing
   the tree; F3 cannot, because the sheet must outlive the panel. The plan names
   the approach and the stop-and-prompt if it fails, but unlike the Review-mode
   technique it has **not** been demonstrated. It is the one place this plan is
   proposing rather than reporting.
2. **How much delete coverage is enough?** Phase 3 stops at "the sheet opens
   with the right candidates" and leaves the sheet's own behaviour to
   `branch_bulk_delete_sheet_test.dart`. If bulk delete warrants end-to-end
   coverage — selection through to `update-ref -d` and the per-branch results
   MADR 0003 specifies — that is a larger piece and should be its own plan.
