---
status: "in-progress"
date: 2026-09-06
associated-madr: "0033-MADR-decompose-the-create-repository-sheet.md"
---

# Decompose the create-repository sheet, and canonicalize what it duplicates

Associated MADR: [0033-MADR-decompose-the-create-repository-sheet.md](0033-MADR-decompose-the-create-repository-sheet.md)

## Goal

Turn `lib/features/workspace/create_repo_sheet.dart` (2176 lines, one 2068-line
state class, 47 methods) into a set of modules with named seams; remove the
duplication it shares with `clone_sheet.dart` and the wider app; and resolve the
four ways the two sheets have drifted — **changing observable behaviour only
where a recorded decision calls for it**, proven by an unedited test suite.

## Scope

### In scope

| Area | Files |
| --- | --- |
| The monolith | `lib/features/workspace/create_repo_sheet.dart` |
| Its sibling | `lib/features/workspace/clone_sheet.dart` |
| Existing shared homes | `lib/features/workspace/{wizard,workspace_widgets,workspace_registration,workspace_provisioning,workspace_targets}.dart`, `lib/features/common/labeled_text_field.dart` |
| Path-helper call sites | `lib/core/storage/{saved_local_repo,saved_connection}.dart`, `lib/core/git/host_fs_service.dart`, `lib/features/tabs/{tab_strip,saved_workspaces_sheet}.dart`, `lib/features/switcher/{current_repo_indicator,connection_switcher}.dart`, `lib/features/dnd/drag_item.dart` |
| New modules | `lib/core/utils/posix_path.dart`, `lib/features/workspace/workspace_pickers.dart`, `lib/features/workspace/workspace_destination.dart`, `lib/features/workspace/wizard_navigation.dart`, `lib/features/workspace/create_repo_pipeline.dart`, `lib/features/workspace/create_repo_steps/` |
| Tests | new unit tests only; the 37 existing sheet tests are **read-only** in phases 1 and 3–5 |

### Out of scope

* **0032's namespace search/recency work.** This plan only prepares the landing
  site (Phase 5). Nothing here changes what the suggestion chips show.
* **Consolidating `ForgeSheetToggle` with `WorkspaceToggleRow`.** The MADR
  establishes these are different affordances, not duplicates; unifying them is
  a design decision nobody has made.
* **Merging the two shared-widget libraries** (`features/workspace/wizard.dart`
  and `features/forge/forge_create_sheet_widgets.dart`). They overlap only at
  `LabeledTextField`, which the forge library already delegates to.
* **`_recomputeTarget` and `_onDestChanged` divergences.** Raised in the MADR;
  they need a decision before code. See *Open questions* below — Phase 3 stops
  and prompts rather than picking.
* Any change to `clone_sheet.dart`'s behaviour. It is edited only to consume
  extracted modules.

### Preconditions

```sh
flutter --version | head -1          # must read: Flutter 3.47.2
flutter pub get --enforce-lockfile   # must say "Got dependencies!"
git status --short                   # must be empty before starting a phase
```

Verified 2026-09-06: the local SDK is Flutter 3.47.2, matching `FLUTTER_VERSION`
in `build_macos.sh:41`.

### Baseline measurements (captured 2026-09-06, at `f9838d1`)

These are the neutrality reference. Phases 1–5 must not move them.

| Metric | Value |
| --- | --- |
| `expect(` across `test/` | **9043** |
| `testWidgets(` across `test/` | **999** |
| `test/create_repo_sheet_test.dart` | 1301 lines, **126** `expect(`, **28** `testWidgets(` |
| `test/create_repo_namespace_test.dart` | 310 lines, **17** `expect(`, **9** `testWidgets(` |
| `test/helpers/create_repo_harness.dart` | 258 lines |
| `test/create_repo_wire_live_test.dart` | 593 lines, 23 `expect(` (live-forge, not run routinely) |

Capture command, re-run at the start of every phase:

```sh
printf 'expect=%s testWidgets=%s\n' \
  "$(grep -rho 'expect(' test/ | wc -l | tr -d ' ')" \
  "$(grep -rho 'testWidgets(' test/ | wc -l | tr -d ' ')"
```

## Implementation Steps

Seven commits across six phases, each independently revertible.

**Phase 0 is split in two (0a, 0b) because it carries the only intentional
behaviour changes**, and they are unrelated to each other. Phases 1 and 3–5 are
behaviour-neutral. **Phase 2 is neutral at 6 of its 8 call sites and
deliberately changes 2**, named there — a consequence of Decision 1 that is
recorded rather than absorbed.

Per `AGENTS.md`, every commit is made with exactly `git commit --no-edit` (the
global `prepare-commit-msg` hook writes the message), and nothing is pushed
unless the maintainer asks in that turn.

---

### Phase 0a — Align `_goBack` with the clone sheet, and pin the invariant

> **Deviation, 2026-09-06 — this phase was rewritten mid-execution.** It was
> written as "fix the `_goBack` defect, alone". Executing its own first step
> disproved the defect: the test was written first and run against the
> unmodified sheet, as required, and it **passed**. `_submitting` is cleared only
> in the `finally` at `create_repo_sheet.dart:867`, which runs after the
> `await Future.delayed(successPopDelay)` and the `Navigator.pop()`, so
> `_submitting` covers the whole window in which `_finished` is true and both
> existing guards already refuse. The maintainer chose **Option A**: keep the
> change and the test, reframed as alignment plus an invariant pin. MADR 0033 is
> amended accordingly. **No behaviour changes in this phase.**

**Why it is still worth doing, and still first.** Two reasons, neither of them a
bug:

1. **Phase 3b cannot extract `_goBack` without choosing a winner.** The two
   bodies differ by one condition. Landing the clone sheet's version here makes
   them byte-identical, so 3b becomes a pure move.
2. **The create sheet's correctness rests on an implicit invariant** — that
   `_submitting` spans the `_finished` window. Nothing enforces it, and **Phase 4
   extracts `_submit()`**, which is precisely the change that could move
   `_submitting = false` earlier and make Back live for real. The test converts
   that invariant into an enforced one before the extraction that threatens it.

**Edits — 2 lines in 1 file:**

1. `create_repo_sheet.dart:322` → `if (_stepIndex == 0 || _submitting || _finished) return;`
2. `create_repo_sheet.dart:2129` (the Back button in `_footer`) →
   `onPressed: _submitting || _finished ? null : _goBack,`

**Test — `test/create_repo_sheet_test.dart`, "Back is inert once a create has
finished".** Raises `successPopDelay` to 1 s locally (the file sets it to zero so
other tests don't wait it out), drives a plain create to completion, and asserts
inside the finished window that the repo registered, the sheet has not popped,
and the Back button's `onPressed` is null. Restores the delay via `addTearDown`
and settles past the timer.

Two hazards this test hit, recorded because either would have been mistaken for
a genuine failure:

* the "Creating…" footer overflows the 1200×900 test surface by 22 px — drain
  the layout exception the way `pumpCreate` does, or the test fails on rendering
  rather than on its assertion;
* the success-pop timer outlives the test unless it is settled past, producing
  `A Timer is still pending`.

**Verification:**

```sh
flutter test test/create_repo_sheet_test.dart
flutter analyze lib/features/workspace/create_repo_sheet.dart
dart format --output=none --set-exit-if-changed lib/features/workspace/create_repo_sheet.dart
```

**Acceptance:** the test **passes both before and after** the 2-line change —
this is an alignment commit, and the execution record must state the
before-result rather than claiming a failing-first run; `_goBack` is
byte-identical between the two sheets afterwards (confirm with the
method-comparison scan); `create_repo_sheet_test.dart` is 29 `testWidgets(`; no
other test file changes; **no observable behaviour changes**.

---

### Phase 0b — Dial eagerly on destination select

**Decision 3 (2026-09-06): yes** — the create sheet should provision eagerly, as
the clone sheet does.

**Why its own commit, and why before the refactor:** this is a behaviour change,
so it cannot live inside a phase that claims neutrality — the same reasoning
that isolates Phase 0a. Landing it here also makes the two `_onDestChanged`
implementations *identical*, so Phase 3 can extract them without a decision
pending.

**Evidence.** `clone_sheet.dart:269–271` calls `ensureProvisioned()` when the
selected destination resolves to `WorkspaceTarget.sshProvision`;
`create_repo_sheet.dart:432–439` does not. Yet the create sheet's
`_destinationSection` renders the `provisioning` "Connecting…" spinner
(`:1372–1386`) — a spinner for a state its own destination control never
initiates — the two Browse buttons do reach it (`ensureProvisioned()` at
`:1203` and `:1223`), but the destination control does not.

**Edit — `create_repo_sheet.dart` `_onDestChanged` (`:432–439`):** append the
clone sheet's trailing block, and its leading comment, so the two bodies match
byte for byte:

```dart
// Switching destination abandons any in-flight provisioning.
await resetProvisioning();
…
if (_target == WorkspaceTarget.sshProvision) {
  await ensureProvisioned();
}
```

**Test — new, in `test/create_repo_sheet_test.dart`:** select a saved SSH
connection from the landing variant and assert the "Connecting…" indicator
appears without submitting. **Sabotage:** run it against the unmodified sheet
first and record the failure — the spinner is currently unreachable by this
path, so a passing-only test would prove nothing.

**Verification:**

```sh
flutter test test/create_repo_sheet_test.dart
flutter analyze lib/features/workspace/create_repo_sheet.dart
dart format --output=none --set-exit-if-changed lib/features/workspace/create_repo_sheet.dart
```

**Acceptance:** the new test fails before the change and passes after;
`_onDestChanged` is byte-identical between the two sheets (confirm with the
method-comparison scan); `create_repo_sheet_test.dart` is 30 `testWidgets(`.

---

### Phase 1 — Adopt the shared widgets that already exist

**1a. `WizardReviewRow`.** `wizard.dart:127` defines it; `create_repo_sheet.dart`
already imports `wizard.dart` and defines an identical private `_reviewRow` at
`:2063`. `clone_sheet.dart` uses the shared widget at 5 call sites; the create
sheet uses it 0 times.

* Delete `_reviewRow` (`:2063–2082`).
* Replace its call sites in `_reviewStep` (`:2000–2062`) with
  `WizardReviewRow(label, value)`.
* `MacosTypography` becomes unused in `_reviewStep`'s signature if nothing else
  needs it — check before removing the parameter, since `WizardStep.body` may
  require the signature.

**1b. Extend `LabeledTextField`, then adopt it.**
`lib/features/common/labeled_text_field.dart:7` already renders exactly the
block the sheet hand-rolls: `caption1` label → `SizedBox(height: 4)` →
`MacosTextField` with `kAppPlaceholderStyle`, `kAppTextFieldDecoration`,
`kAppTextFieldFocusedDecoration`. Two additive parameters are needed:

```dart
/// Rendered below the field. The wizard's hint slot.
final Widget? hint;
/// Overrides the normal/focused decorations — used for inline validation.
final bool showError;
```

`showError` selects `kAppTextFieldErrorDecoration` /
`kAppTextFieldErrorFocusedDecoration`, both already in `field_styles.dart:28,34`.

The sheet's 12 `MacosTextField` instances are **not** uniformly adoptable.
Classified by inspection:

| Lines | Shape | Adoptable in 1b? |
| --- | --- | --- |
| 1513, 1536, 1556, 1912, 1945, 1964 | label + 4 px gap + field (+ hint) | **yes** |
| 1595 | same, plus error decoration | **yes**, needs `showError` |
| 1611, 1652, 1677 | second field of a pair, no label of its own | **no** — would need a label-less variant |
| 1739, 1822 | inside a `Row`/`Expanded` beside a Browse button | **no** — would need a trailing-widget variant |

**Decision 4 (2026-09-06): leave them.** Adopt the 7; the other 5 stay
hand-rolled and are named in the execution record. Inventing a label-less and a
trailing-widget variant to reach 12/12 would add API surface for its own sake;
revisit only when a third caller needs the same shape.

**Verification:**

```sh
flutter test test/create_repo_sheet_test.dart test/create_repo_namespace_test.dart
flutter test test/                                  # LabeledTextField has other consumers
flutter analyze
dart format --output=none --set-exit-if-changed \
  lib/features/common/labeled_text_field.dart lib/features/workspace/create_repo_sheet.dart
```

The full-suite run is not optional here: `LabeledTextField` is used by
`connection_form.dart`, `add_worktree_sheet.dart`, `edit_entry_sheets.dart` and
— via `ForgeSheetField` — all three forge create forms. A change to it reaches
all of them.

**Acceptance:** all tests green with **no test file edited**; `expect(` = 9043
and `testWidgets(` = **1001** (999 baseline + one test each from Phases 0a and
0b — state the number the phase actually observed);
`create_repo_sheet.dart` is shorter by roughly 20 (`_reviewRow`) + ~60 (7 blocks
× ~8 lines saved) lines.

---

### Phase 2 — Canonicalize the path helpers

**The most dangerous phase. It is not a rename.**

`lib/` carries **13 private path-helper definitions**. `_basename` exists **8
times in 2 behaviourally distinct families**, verified by executing all three
distinct implementations verbatim:

| Input | Family A (×6) | `drag_item:70` | `create_repo_sheet:2163` |
| --- | --- | --- | --- |
| `a/b//` | `b` | *(empty)* | `b` |
| `/` | `/` | *(empty)* | *(empty)* |
| `//` | `//` | *(empty)* | *(empty)* |
| `/a/b`, `a//b`, `/repo/`, `repo`, `` | all agree | | |

**And `stripTrailingSlashes` must NOT be unified into one function.** The two
implementations differ by one character and *both contracts are load-bearing*:

| Input | `host_fs_service.dart:186` (`end > 0`) | `create_repo_sheet.dart:2169` (`end > 1`) |
| --- | --- | --- |
| `/` | *(empty)* | `/` |
| `//`, `///` | *(empty)* | `/` |
| `/a/`, `a//`, `` | identical | identical |

The `end > 0` behaviour is a **safety mechanism**, not an accident.
`HostFsService.removeDirGuarded` (`:138–176`) reads:

```dart
final normalizedParent = _stripTrailingSlashes(expectedParent);
if (normalizedParent.isEmpty) {
  // expectedParent was '/' (or only slashes) — never delete at the root.
  throw ArgumentError('refusing to delete directly under /');
}
```

That guard is the thing standing between a caller and `rm -rf` at the
filesystem root, and it fires **only because `/` collapses to empty**. It also
governs `HostFsService.joinPath` (`:180–184`), used at
`create_repo_sheet.dart:484,917`, `clone_sheet.dart:329`,
`clone_controller.dart:170` and `remote_directory_browser.dart:265` — the last
of which can legitimately pass `/` while browsing the host root.

**Two existing tests bear on this, and they are not equally protective:**

* `test/host_fs_service_test.dart:202` pins `joinPath('/', 'x') == '/x'`. Swap in
  the `end > 1` variant and this **fails** (`'//x'`). Good.
* `test/host_fs_service_test.dart:181` pins the root refusal as
  `refuses(path: '/x', parent: '/', name: 'x')` — but it asserts only
  `throwsArgumentError`. Traced by reading: under `end > 1`, `normalizedParent`
  becomes `/`, the root guard is **skipped**, and control falls to the
  `path != '$normalizedParent/$expectedName'` check, which throws
  `ArgumentError` anyway — from the wrong branch, with the wrong message. **This
  test would still pass while the dedicated root guard became dead code.**

**Steps, in this order:**

1. **Tighten the weak test first, before touching any helper.** Change
   `host_fs_service_test.dart:181`'s root case to assert the *message*
   (`'refusing to delete directly under /'`), not just the type. Then
   **demonstrate** the claim above: apply the `end > 1` body to a scratch copy of
   `host_fs_service.dart`, run the test, and record that the tightened
   assertion fails where the old one passed. Per `AGENTS.md`, run this against a
   copy in the scratchpad — never by dirtying the tree, and never cleaned up
   with `git checkout --`.
2. **Create `lib/core/utils/posix_path.dart`** with three functions and explicit
   contracts:
   * `String basename(String path)` — one chosen family (see decision below).
   * `String dirname(String path)` — replacing `_dirOf`
     (`create_repo_sheet:2152`, `clone_sheet:1064`, identical). ~~and
     `environment_probe.dart:249`'s `_dirname`.~~
     > **Deviation, 2026-09-06 — step wrong as written; maintainer chose to
     > leave `environment_probe` alone.** `_dirname` is not the same function
     > as `_dirOf`; they share a name and disagree on **4 of 7** probed inputs,
     > verified by executing both verbatim:
     > `_dirOf('/srv/repo/')` = `/srv` vs `_dirname('/srv/repo/')` = `/srv/repo`;
     > `_dirOf('git')` = `/` vs `_dirname('git')` = `''`;
     > also `a/b//` and `''`. `_dirOf` treats a trailing slash as
     > insignificant; `_dirname` treats it literally, and its `''` for a bare
     > name is documented in place as deliberate ("returning the input
     > unchanged would otherwise inject a nonsensical literal-name PATH
     > entry"). Merging them would change host `$PATH` parsing. This is the
     > same hazard the phase already records for `stripTrailingSlashes`, and
     > the same resolution: **canonicalize on behaviour, not on name.**
     > `environment_probe.dart` is therefore **out of scope for this phase**,
     > and its `_dirname` keeps a comment saying why it is not the shared
     > helper.
   * `String stripTrailingSlashes(String path)` — the **root-collapsing**
     (`end > 0`) contract, documented as such, with `removeDirGuarded`'s
     dependence named in the doc comment.
   * `String stripTrailingSlashesKeepRoot(String path)` — the `end > 1`
     contract, for the create sheet's `dest` normalisation (`:479`) and
     `_basenameOf`. **Two functions, two names, two doc comments.** Do not add a
     boolean flag: a caller that passes the wrong flag gets the `rm -rf` guard
     silently disabled, which is precisely the failure this phase exists to
     prevent.
3. **Pin the contracts with unit tests before switching any call site** —
   `/`, `//`, `///`, `a/b//`, `/a/b`, `a//b`, `/repo/`, `repo`, `""` for each
   function. These are pure functions; there is no excuse for an unpinned edge.
4. **Switch the 8 `basename` definitions**, one file per step, checking each
   call site's input against the chosen family *before* switching it:

   | File | Definition | Call sites | Input |
   | --- | --- | --- | --- |
   | `core/storage/saved_local_repo.dart` | 137 | 135 | `repoPath` |
   | `core/storage/saved_connection.dart` | 112 | 109 | `path` |
   | `features/tabs/tab_strip.dart` | 14 | 144 | `tab.repoPath!` |
   | `features/tabs/saved_workspaces_sheet.dart` | 293 | 132, 232, 256 | `repository.repoPath`, `tab.repoPath ?? ''` |
   | `features/switcher/current_repo_indicator.dart` | 18 | 58 | `repoPath` |
   | `features/switcher/connection_switcher.dart` | 28 | 632, 662 | `repo` |
   | `features/dnd/drag_item.dart` | 70 | 65 | `paths.first` |
   | `features/workspace/create_repo_sheet.dart` | 2163 | 1192, 1217 | picked/browsed folder |

   **Decision 1 (2026-09-06): Family A.** It is the majority (6 of 8) and never
   returns empty for a non-empty input, which is the right property for a
   display label.

   **This changes behaviour at exactly 2 of the 8 sites** — `drag_item.dart:70`
   and `create_repo_sheet.dart:2163` — and only for inputs with two or more
   trailing slashes, or a bare root. Assessed per site rather than assumed:

   * `drag_item.dart` — its own doc comment says the helper "tolerates a
     trailing slash" (singular). Family A tolerates any number and never yields
     an empty label, so the switch **matches the documented intent** and removes
     the empty-drag-label case for `a/b//`.
   * `create_repo_sheet.dart:1192,1217` — the inputs come from
     `getDirectoryPath()` (the native picker) and `RemoteDirectoryBrowserSheet`,
     whose paths are built by `HostFsService.joinPath`
     (`remote_directory_browser.dart:265`), which never emits a trailing slash.
     The change is therefore **not reachable in practice** at these call sites;
     it is a contract change, not an observed one. Confirm this by inspection
     during execution rather than trusting this paragraph.

   Family A's contract is already partly pinned by
   `test/saved_local_repo_test.dart:219–231` (`/a/b/c`, `/a/b/c/`, and a
   no-slash path). The new `posix_path_test.dart` adds the root and
   double-slash cases those tests do not reach.
5. **Switch `_dirOf` / `_stripTrailingSlashes`** call sites:
   `create_repo_sheet:400,479,528,2164`, `clone_sheet:232`,
   `host_fs_service:153,182`. ~~`environment_probe:221,249`~~ — excluded by the
   deviation above.

**Verification:**

```sh
flutter test test/posix_path_test.dart          # new, must exist before step 4
flutter test test/host_fs_service_test.dart
flutter test                                    # full suite — 8 files across 5 features
flutter analyze
```

**Acceptance:** `grep -rn "static String _basename\|^String _basename\|String _dirOf\|String _dirname\|_stripTrailingSlashes(String" lib/ | wc -l`
drops from **13** to **0**; `posix_path_test.dart` pins all 9 edge inputs per
function and each was seen to fail against a deliberately wrong body; the
`removeDirGuarded` root-refusal test asserts the message; full suite green with
no existing test edited **except** the deliberate `:181` tightening, which is
recorded as such.

---

### Phase 3 — Extract the shared sheet code as standalone functions

Form follows `workspace_registration.dart`, whose own library comment states the
convention: shared logic lives in "standalone functions (not sheet methods) so
there is exactly one implementation to reason about." No shared base class, no
widened mixin — the sheets are only ~60 % alike and inheritance would re-create
the coupling this phase removes.

**3a. `lib/features/workspace/workspace_pickers.dart`** — the 29 byte-identical
picker lines.

* `_pickLocalParent` (`create:1169–1181`, `clone:401–413`) → `Future<String?>
  pickLocalDirectory()`. Returns the path; the caller owns `setState` and the
  `_picking` flag, so the function needs no `BuildContext`.
* `_browseRemote` (`create:1222–1238`, `clone:415–431` — **identical, 16
  lines**) → `Future<String?> browseRemoteDirectory(BuildContext, {String? initialPath})`.
* The create sheet's `_pickLocalFolder` (`:1183–1200`) and `_browseRemoteFolder`
  (`:1202–1220`) are the same two calls plus `_name.text = _basenameOf(path)`;
  they stay in the sheet as thin callers.

**3b. `lib/features/workspace/wizard_navigation.dart`** — `_goNext`
(**identical, 9 lines**) and `_goBack` (identical after Phase 0a), plus
`_activeSteps`. Prefer a small `WizardNavigator` value type over a mixin so it
is directly unit-testable; the sheets keep `_stepIndex` and pass it in.

**3c. `lib/features/workspace/workspace_destination.dart`** — a
`WorkspaceDestinationSection` widget replacing `_destinationSection`
(`create:1340–1388`, `clone:516–566`), **95.0 % identical**. The only difference
is hint wording, so the widget takes the two hint strings (or a `verb`)
as parameters.

**3d. The `_register` dispatcher** — **31 byte-identical lines**
(`create:1128–1158`, `clone:359–389`). Move into `workspace_registration.dart`
beside the functions it already dispatches to, as
`Future<bool> registerAndActivate({required WorkspaceTarget target, ...})`.

**3e. `_recomputeTarget`.** **Decision 2 (2026-09-06): yes** — adopt the clone
sheet's form as canonical. It computes into a local `final WorkspaceTarget
target` and commits `_target` once, where the create sheet
(`create_repo_sheet.dart:391–407`) assigns `_target` and reads it back within
the same branch. The two are **equivalent as written today** — the MADR
establishes this — so applying the clone sheet's form to the create sheet is
behaviour-neutral, and the pair then extracts cleanly.

**`_onDestChanged` needs no work here.** Phase 0b already made the two bodies
byte-identical, so it extracts alongside 3a–3d with no decision outstanding.
Verify that with the method-comparison scan before extracting; if the bodies are
not identical, Phase 0b was not applied as specified — stop rather than
reconciling them inside a neutral phase.

**Verification:**

```sh
flutter test test/create_repo_sheet_test.dart test/create_repo_namespace_test.dart
flutter test test/clone_sheet_test.dart
flutter test
flutter analyze
```

**Acceptance:** the six identical-method pairs are gone — verified by re-running
the method-comparison scan and showing 0 byte-identical methods remaining
between the two sheets; both sheets shrink; **no test file edited**; `expect(`
and `testWidgets(` unchanged from the Phase 2 baseline.

---

### Phase 4 — Extract the create pipeline

The highest-value phase: 424 lines currently reachable only by pumping a widget
become directly unit-testable. This is the seam-shaped gap
[0030](0030-MADR-test-coverage-gaps-are-shaped-not-sized.md) names.

**The seams are already drawn.** `_submit()` (`:450–873`) carries eight banner
comments, verified at these exact lines:

| Line | Phase |
| --- | --- |
| 515 | `// --- Pre-checks ---` |
| 579 | `// --- Existing-origin guard ---` |
| 621 | `// --- Step 1: init (skipped when the folder is already a repo) ---` |
| 647 | `// --- Identity: local user.name / user.email ---` |
| 658 | `// --- Step 2: optional initial commit ---` |
| 686 | `// --- Step 3: wire origin (mode-specific) ---` |
| 816 | `// --- Step 4: post-create verification ---` |
| 841 | `// --- Register + activate (shared matrix) ---` |

**New file `lib/features/workspace/create_repo_pipeline.dart`:**

* An input record. `_submit()` reads **22 distinct state members** —
  `_addReadme`, `_branch`, `_commitAll`, `_createParents`, `_description`,
  `_folder`, `_forge`, `_forgePath`, `_host`, `_hostEdited`, `_isLocalTarget`,
  `_name`, `_parent`, `_pickedFolder`, `_pickedParent`, `_private`, `_remote`,
  `_remoteUrl`, `_replaceOrigin`, `_source`, `_defaultHost`, `_onForge` — plus
  `_executor`. The record carries **resolved values, not controllers**: pass
  `String name`, not `TextEditingController`. A record of controllers is the
  form state a second time, not a boundary.
* A result type carrying `dest`, warnings, and an error, so the sheet keeps
  ownership of `setState`, `_error`, `_completedWarning` and `_finished`.
* The eight phases as private functions in that file, with the existing helpers
  (`_writeIdentityConfig:874`, `_writeReadmeAndCommit:906`,
  `_commitAllContents:958`, `_pushInitial:1003`, `_ensureForgeOrigin:1046`,
  `_verifyOrigin:1104`) moved alongside them.
* **No `BuildContext`, no `setState`, no `ref` inside the pipeline.**
  `ensureProvisioned()` and `_register` stay in the sheet, on either side of the
  pipeline call; that keeps the extraction free of Riverpod and widget
  lifecycle.

**New tests** (`test/create_repo_pipeline_test.dart`), written **after** the
move lands, over a fake `CommandExecutor` — the pattern
`test/helpers/create_repo_harness.dart` already establishes with
`FakeCreateExecutor`. Minimum coverage: the existing-origin guard's refuse and
replace paths; init skipped when the folder is already a repo; warnings that
must not fail the run; and each of the four `_RemoteMode` branches through
*Step 3*.

**Verification:**

```sh
flutter test test/create_repo_sheet_test.dart test/create_repo_namespace_test.dart
flutter test
flutter analyze
```

**Acceptance:** `_submit()` in the sheet is under ~60 lines and contains no forge
or git command construction; the pipeline file has no `flutter/widgets` or
`riverpod` import; the 37 existing tests pass **unedited**; new pipeline tests
land in a **separate follow-up commit**, so the neutrality evidence stays
uncontaminated by tests written to match the refactor.

---

### Phase 5 — Extract the step bodies

`build` + 21 widget methods span `:1240–2151` (912 lines). Move each step body
into `lib/features/workspace/create_repo_steps/`:

| New file | From |
| --- | --- |
| `source_step.dart` | `_sourceStep:1429`, `_sourceButton:1416` |
| `details_step.dart` | `_detailsStep:1499`, `_namespaceSuggestions:1455`, `_localFolderPicker:1693`, `_sshFolderField:1730`, `_commitAllToggle:1766`, `_localParentPicker:1776`, `_sshParentField:1813` |
| `remote_step.dart` | `_remoteSection:1860`, `_remoteButton:1980` |
| `review_step.dart` | `_reviewStep:2000` |
| `create_repo_footer.dart` | `_footer:2084` |

Each takes the state it needs as constructor parameters plus callbacks; none
reaches back into the sheet's `State`. `_sourceButton` and `_remoteButton` are
the same segmented-selector shape parameterised differently and collapse into
one `_segmentButton<T>` in the shared step library.

**This is where 0032's namespace control lands** — as its own widget in
`details_step.dart`'s directory, not as more lines in the sheet.

**Verification:** as Phase 4, plus a visual check of all four wizard steps in a
built app (`./build_macos.sh --unsigned --install`), since widget-tree moves can
pass tests and still change layout.

**Acceptance:** `create_repo_sheet.dart` under ~700 lines; 37 existing tests
pass unedited; `expect(`/`testWidgets(` unchanged.

## Verification

Run at the end of every phase, in this order:

```sh
flutter analyze                                  # must be clean on the first pass
dart format --output=none --set-exit-if-changed <each file the commit stages>
flutter test                                     # full suite
printf 'expect=%s testWidgets=%s\n' \
  "$(grep -rho 'expect(' test/ | wc -l | tr -d ' ')" \
  "$(grep -rho 'testWidgets(' test/ | wc -l | tr -d ' ')"
git diff --stat -- test/                         # phases 1, 3-5: must be empty
```

Notes that are not optional:

* **`dart format` must run on the files in place**, never on a copy outside the
  package. Outside its package `dart format` cannot read `sdk: ^3.12.2` from
  `pubspec.yaml`, falls back to a different default language version, and wraps
  differently — this produced a false "10 pre-existing hunks" finding during
  0031.
* **Do not run `dart format lib/ test/` globally** (`AGENTS.md`).
* **Never chain the format check with `&&` before `git commit`** — during 0031 a
  `dart format … && echo OK` short-circuited only the `echo`, and an 81-column
  line reached the commit.
* `lib/core/providers/app_providers.dart` is classified binary by grep; use
  `grep -a` if this plan's greps ever reach it.
* **The `live-forge` suite is not part of routine verification.** It is mutating
  and maintainer-run only. One explicitly-requested run after Phase 4
  (`flutter test --run-skipped -t live-forge test/create_repo_wire_live_test.dart`)
  is the appropriate check that the extracted pipeline still works against a real
  forge — and it must not be run unprompted.

### Acceptance criteria for the plan as a whole

1. **Phase 0b** adds a test that fails against the unmodified sheet and passes
   after; the failure output is in the execution record. **Phase 0a** adds a
   test that passes *both* before and after — it pins an invariant rather than
   fixing a defect (see the deviation note on that phase), and the execution
   record states the before-result rather than claiming a failing-first run.
2. Phases 1–5 leave `test/` byte-identical apart from files **added** in
   follow-up commits, and Phase 2's single deliberate assertion tightening.
3. `expect(` and `testWidgets(` counts across `test/` are unchanged from the
   post-Phase-0 baseline at the end of every phase.
4. `grep` finds **1** remaining private `_basename` / `_dirOf` / `_dirname` /
   `_stripTrailingSlashes` definition in `lib/`, down from 13 — and that
   survivor is `environment_probe.dart:249`'s `_dirname`, deliberately kept
   under the deviation recorded in Phase 2 and carrying a comment saying so.
   ~~0 remaining.~~
5. The method-comparison scan finds 0 byte-identical methods shared between
   `create_repo_sheet.dart` and `clone_sheet.dart`.
6. `create_repo_pipeline.dart` imports neither `flutter/widgets` nor
   `flutter_riverpod`.
7. `flutter analyze` clean at every phase, first pass.
8. Every new check has been seen to fail against a deliberately broken input,
   run against a scratchpad copy — never by dirtying the tree, and never
   restored with `git checkout --`.


## Execution record

### Phase 0a — 2026-09-06 — *complete (reframed mid-execution)*

**Deviation.** The phase was written as "fix the `_goBack` defect, alone".
Executing its own first step disproved the defect. Full account in the phase's
deviation note above and in MADR 0033's *Amendments*; the maintainer chose
Option A (keep the change and the test, reframed as alignment + invariant pin).

**What the sabotage actually did.** Three runs, because the experiment was not
valid until the third — recorded in full because the first two failures would
each have been mistaken for the predicted one:

```
run 1  A RenderFlex overflowed by 22 pixels on the right.      <- rendering, not the assertion
run 2  A Timer is still pending even after the widget tree was disposed.
       'package:flutter_test/src/binding.dart': line 2543 '!timersPending'
run 3  00:00 +1: All tests passed!                             <- against UNMODIFIED lib/
```

Run 3 is the result that invalidated the phase's premise.

**Edits applied** — 2 lines, `lib/features/workspace/create_repo_sheet.dart`:

```diff
@@ -321,3 +321,3 @@   void _goBack() {
-    if (_stepIndex == 0 || _submitting) return;
+    if (_stepIndex == 0 || _submitting || _finished) return;
@@ -2128,3 +2128,3 @@             secondary: true,
-            onPressed: _submitting ? null : _goBack,
+            onPressed: _submitting || _finished ? null : _goBack,
```

**Purpose achieved (the reason the phase survived).** `_goBack` is now
byte-identical between the two sheets, so Phase 3b's extraction is a pure move:

```
diff <(sed -n '321,327p' create_repo_sheet.dart) <(sed -n '164,170p' clone_sheet.dart)
  -> no output; IDENTICAL
```

The footer Back buttons now differ only by one indentation level (clone's is
nested deeper); the logic is identical.

**Verification output:**

```
flutter test test/create_repo_sheet_test.dart   00:05 +29: All tests passed!
flutter analyze lib/features/workspace/create_repo_sheet.dart
                                                No issues found! (ran in 3.9s)
dart format --output=none --set-exit-if-changed  Formatted 2 files (0 changed)
flutter test (full suite)                       03:29 +3572 ~2: All tests passed!
```

**Counts.** `expect(` 9043 -> **9046**, `testWidgets(` 999 -> **1000** — the +3
and +1 are Phase 0a's single new test. `create_repo_sheet_test.dart` is now 29
`testWidgets(`, as the acceptance criterion requires. No other test file was
touched.

**Behaviour.** None changed. The test passes identically before and after the
2-line edit; that is the point of an alignment commit, and it is stated here
rather than dressed up as a failing-first run.

### Phase 0b — 2026-09-06 — *complete*

**Edit applied** — `lib/features/workspace/create_repo_sheet.dart`
`_onDestChanged` (`:432`), bringing it byte-for-byte in line with
`clone_sheet.dart:261`:

```diff
   Future<void> _onDestChanged(String? connectionId) async {
+    // Switching destination abandons any in-flight provisioning.
     await resetProvisioning();
     setState(() { ... });
+    if (_target == WorkspaceTarget.sshProvision) {
+      await ensureProvisioned();
+    }
   }
```

**Sabotage — seen to fail, for the right reason.** The test was written first
and run against the unmodified sheet:

```
Expected: exactly one matching candidate
  Actual: _TextWidgetFinder:<Found 0 widgets with text "Connecting…": []>
   Which: means none were found but one was expected
00:00 +0 -1: selecting an SSH destination dials without waiting for submit [E]
```

That is the assertion failing, not a rendering or timer artifact — the
distinction Phase 0a's three-run sabotage made necessary.

**Test.** `test/create_repo_sheet_test.dart`, "selecting an SSH destination
dials without waiting for submit". Pumps `CreateRepositorySheet.landing()` with
a `_ParkingProvisionConnection` whose `beginProvisioning` returns a `Completer`
future, so the dial stays in flight and `provisioning` remains true; selects the
saved host from the Destination popup and asserts "Connecting…" is on screen
without any submit. Completes the future and settles so no timer outlives the
test.

**Verification output:**

```
flutter test test/create_repo_sheet_test.dart   00:05 +30: All tests passed!
flutter analyze lib/features/workspace/create_repo_sheet.dart
                                                No issues found! (ran in 2.8s)
dart format --output=none --set-exit-if-changed  Formatted 2 files (0 changed)
flutter test (full suite)                       03:24 +3573 ~2: All tests passed!
```

`dart format` initially reported `Changed test/create_repo_sheet_test.dart`; it
was formatted in place and re-checked clean before the commit, rather than the
check being skipped.

**Counts.** `expect(` 9046 -> **9047**, `testWidgets(` 1000 -> **1001**;
`create_repo_sheet_test.dart` is 30 `testWidgets(`.

**Behaviour changed, as decided.** Selecting a saved SSH destination now dials
immediately instead of waiting for submit, which makes the `provisioning`
spinner reachable from the destination control. Decision 3.

**What Phases 0a and 0b together bought.** Re-running the method-comparison
scan: byte-identical methods between the two sheets went **6 -> 8** and
duplicated lines **83 -> 102**, because `_goBack` (was 85.7 % alike) and
`_onDestChanged` (was 80.0 %) are now exact matches. The duplication figure
going *up* is the intended outcome — Phase 3 removes all 102 lines in one move,
and it can only do that for methods that agree. One near-duplicate remains for
Phase 3e: `_recomputeTarget`.

### Phase 1 — 2026-09-06 — *complete*

**1a — `WizardReviewRow` adopted.** The private `_reviewRow` (21 lines) is gone
and its **7** call sites in `_reviewStep` now use the shared widget from
`wizard.dart:127`, which this file already imported and which `clone_sheet.dart`
was already using at 5 call sites. `_reviewStep` keeps its
`MacosTypography` parameter because `WizardStep.body` is typed
`Widget Function(MacosTypography)`; it is simply unused now, as it is in the
clone sheet.

**1b — `LabeledTextField` extended, then adopted at 7 of 12 sites.** Two
additive parameters on `lib/features/common/labeled_text_field.dart`:

* `Widget? hint` — rendered inside the same padded column, below the field.
  `FieldHint` already carries its own `EdgeInsets.only(top: 4)`, so this
  composes with no extra spacing.
* `bool showError` — swaps in `kAppTextFieldErrorDecoration` /
  `kAppTextFieldErrorFocusedDecoration`, which `field_styles.dart` already
  defined but this widget could not reach.

Adopted: repository name, namespace, initial branch, git-identity name (the
`showError` case), custom remote URL, forge host, project description.
**Left hand-rolled, as decided (Decision 4)** — 5 fields, confirmed by grep at
`:1597` `_authorEmail` (second of a pair, no label of its own), `:1638`
`_localLabel` and `:1663` `_remoteLabel` (same shape), `:1725` `_folder` and
`:1808` `_parent` (inside a `Row` beside a Browse button).

**A risk that had to be measured, not reasoned about.** `LabeledTextField`'s
inner `Column` uses `CrossAxisAlignment.start`, while `_detailsStep`'s uses
`CrossAxisAlignment.stretch` — so the adopted fields could have collapsed to
their intrinsic width. A temporary probe test measured the rendered geometry of
the repository-name field before and after:

```
before  PROBE name field size=Size(376.0, 29.0) topLeft=Offset(412.0, 361.0)
after   PROBE name field size=Size(376.0, 29.0) topLeft=Offset(412.0, 361.0)
        PROBE MacosTextField count on Details=5   (unchanged both sides)
```

Identical, so `MacosTextField` does expand under a `start` column. The probe was
run after the first adoption (before doing the other six) and again at the end,
then deleted; it is recorded here rather than kept, because it measured a
one-time migration risk, not an invariant.

**One analyzer miss, recorded rather than glossed.** The repo requires new code
to be analyzer-clean on the first pass. It was not: the first version of the
`hint` slot used `if (hint != null) hint!,` and `flutter analyze` returned
`use_null_aware_elements` (info). Fixed to `?hint,` before proceeding.

**Verification output:**

```
flutter analyze (whole project)                 No issues found! (ran in 4.2s)
dart format --output=none --set-exit-if-changed  Formatted 2 files (0 changed)
flutter test test/create_repo_sheet_test.dart
     test/create_repo_namespace_test.dart       00:05 +39: All tests passed!
flutter test (full suite)                       03:28 +3573 ~2: All tests passed!
```

The full-suite run is load-bearing here, not routine: `LabeledTextField` is also
used by `connection_form.dart`, `add_worktree_sheet.dart`,
`edit_entry_sheets.dart` and — through `ForgeSheetField` — all three forge
create forms.

**Neutrality.** `expect(` **9047** and `testWidgets(` **1001**, both unchanged
from Phase 0b. `git diff --stat -- test/` is **empty** — no test file was edited
in this phase.

**Size.** `create_repo_sheet.dart` 2180 -> **2130** lines (1a -23, 1b -27).
Hand-rolled `MacosTextField` blocks 12 -> **5**; `LabeledTextField` call sites
0 -> **7**.

### Phase 2 — 2026-09-06 — *complete*

**Deviation.** Step 2/5's instruction to fold `environment_probe.dart:249`'s
`_dirname` into the shared helper was wrong as written; the maintainer chose to
leave that file alone. Recorded in full in the phase's step 2 above. Acceptance
criterion 4 changed from 13 -> 0 private helpers to **13 -> 1**.

**Step 1 — the weak test was tightened first, and the tightening was proved
necessary.** `host_fs_service_test.dart`'s refusal matrix asserted only
`throwsArgumentError`. It now pins *which* guard fired, via a `because`
parameter, for the root case. Demonstrated in a throwaway `git worktree` (the
real tree was never dirtied, and nothing was restored with `git checkout --`),
with `_stripTrailingSlashes` mutated to the root-preserving `end > 1`:

```
A) tightened assertion, sabotaged helper  -> FAILS, correctly:
   Expected: throws <ArgumentError> with `message`:
             contains 'refusing to delete directly under /'
     Actual: threw ArgumentError:
             <Invalid argument(s): refusing to delete: path is not the
              expected parent/name>
   (plus: helpers joinPath  Expected: '/x'  Actual: '//x')

B) ORIGINAL type-only assertion, SAME sabotaged helper:
   00:00 +10: removeDirGuarded refusal matrix — never reaches the executor
   00:00 +11: helpers joinPath   [E]   Expected: '/x'  Actual: '//x'
```

**B is the point of the exercise.** The refusal matrix **passed** while the
root guard had become dead code — `removeDirGuarded` still threw, but from the
path/name-mismatch branch with the wrong message. Only `joinPath` caught the
regression. Had the merge been made on the strength of that matrix, the
`rm -rf /` guard would have been silently disabled by a green suite.

**Step 2 — `lib/core/utils/posix_path.dart`.** Four functions, and the module
doc states the rule the phase turned on: *canonicalized on behaviour, not on
name.* Two pairs deliberately keep separate contracts —
`stripTrailingSlashes` (root -> `''`, which `removeDirGuarded` and `joinPath`
depend on) versus `stripTrailingSlashesKeepRoot` (root preserved, for the create
sheet's `dest` normalisation); and `dirname` versus `EnvironmentProbe`'s
`_dirname`, per the deviation. **No boolean flag**, deliberately: a caller who
passes the wrong flag silently disables the guard.

Before writing any expectation, all four were run against the originals they
replace on all 9 edge inputs: **`ALL FOUR match their original implementations
on every input.`**

**Step 3 — contracts pinned, and every one seen to fail.** `posix_path_test.dart`
(11 tests). Four mutations in a scratch worktree, each isolating exactly its own
test:

```
basename: empty fallback              -> basename never returns empty for a non-empty path
dirname: slash <= 0 -> slash < 0      -> dirname gives root when there is no parent above it
stripTrailingSlashes: end>0 -> end>1  -> stripTrailingSlashes collapses a bare root to empty
                                         — the rm -rf guard depends on it
KeepRoot: end>1 -> end>0              -> stripTrailingSlashesKeepRoot keeps a bare root
```

The first pass of this check only showed "1 test failed" per mutation; the run
was repeated to name *which* test, because "something failed" would not have
distinguished a working instrument from a coincidence.

**Steps 4-5 — 12 definitions replaced across 10 files.** Six Family A copies
(`saved_local_repo`, `saved_connection`, `tab_strip`, `saved_workspaces_sheet`,
`current_repo_indicator`, `connection_switcher`) were pure renames — identical
bodies. Then `drag_item.dart` and `create_repo_sheet.dart`'s `_basenameOf`
(**the two behaviour changes**), `_dirOf` in both sheets -> `dirname`, and
`host_fs_service`'s `_stripTrailingSlashes` -> the shared root-collapsing one.

**Acceptance criterion 4:** private path helpers in `lib/` **13 -> 1**. The
survivor is `environment_probe.dart:249`, now carrying a comment naming the four
inputs on which it disagrees with the shared `dirname` and why it stays.

**Two process failures in this phase, recorded rather than glossed:**

* **I ran `dart format lib/` globally**, which `AGENTS.md` explicitly forbids.
  It changed nothing outside the 11 files this phase already touched (verified
  with `git status --short -- lib/`), so there was no damage — but the rule
  exists so that a formatting sweep can never hide inside a behavioural diff,
  and it was broken.
* **An import-sorting script scrambled `create_repo_sheet.dart`'s directive
  block**, merging `dart:`, `package:` and relative imports into one
  alphabetical list. `flutter analyze` caught it (6 `directives_ordering`
  infos); the block was rebuilt as three sorted sections.

**Verification output:**

```
flutter analyze (whole project)   No issues found! (ran in 3.4s)
dart format --output=none --set-exit-if-changed   (0 changed)
flutter test (full suite)         03:24 +3584 ~2: All tests passed!
```

**Counts.** `expect(` 9047 -> **9078** (+31, all in the new
`posix_path_test.dart`); `testWidgets(` **1001**, unchanged. `test/` changes are
the two this phase authorised and no others: `posix_path_test.dart` added, and
the single deliberate assertion tightening in `host_fs_service_test.dart`.

**Behaviour.** Changed at exactly the 2 sites Decision 1 predicted, and only for
inputs with two or more trailing slashes or a bare root: `drag_item` no longer
renders an empty drag label for `a/b//`, and the create sheet's browsed-folder
name follows the same family. Confirmed by inspection that
`create_repo_sheet.dart`'s two call sites receive paths from `getDirectoryPath()`
and from `HostFsService.joinPath` (via `remote_directory_browser.dart:265`),
neither of which can emit a trailing slash — so that site's change remains a
contract change, not an observed one.

## Rollout and Rollback

**Rollout.** Seven commits in order. Phases 1 and 3–5 are behaviour-neutral and
can land in any batch; **Phases 0a and 0b must land first**, because everything
after them asserts neutrality against a baseline that includes both. Phase 2 should
land alone and be given a full-suite run and a manual pass over the tab strip,
switcher and drag labels, because it is the only phase whose blast radius
extends outside the workspace feature.

**Rollback.** Each phase is a single commit touching a disjoint file set, so
`git revert <sha>` restores the prior state without stranding a later phase —
with two ordering constraints:

* Reverting **Phase 2** after Phase 3+ have landed requires restoring the
  private path helpers the later phases now import from `posix_path.dart`.
  Revert Phase 2 last, or not at all.
* Reverting **Phase 0a** re-splits the two `_goBack` bodies, so Phase 3b's
  extraction no longer has a single winner to move, and drops the invariant pin
  that Phase 4 needs. Revert Phase 3 and Phase 4 first, or not at all.
* Reverting **Phase 0b** after Phase 3 has landed is not a clean revert: Phase 3
  extracted the unified `_onDestChanged` on the assumption that 0b applied.
  Revert Phase 3 first, or re-apply the divergence by hand in the extracted
  function and say so.

There is no data migration, no persisted format change, and no user-visible
behaviour change in phases 1 and 3–5, so rollback there carries no cleanup
beyond the revert itself. The two exceptions are the decisions: Phase 0b's eager
dial is user-visible (a spinner that now appears on destination select), and
Phase 2's Family A switch changes what a drag label shows for a path with two or
more trailing slashes. Both belong in their commit message and the handoff.

## Decisions — resolved 2026-09-06 by the maintainer

All four questions this plan raised are answered. Recorded here with the step
each one gates and the consequence it carries.

| # | Question | Decision | Gates | Behaviour change? |
| --- | --- | --- | --- | --- |
| 1 | `basename` family | **Family A** (split, drop empties, take last) | Phase 2 step 4 | **Yes** — 2 of 8 sites, unreachable in practice at one of them |
| 2 | `_recomputeTarget` canonical form | **Yes** — adopt the clone sheet's | Phase 3e | No — equivalent as written |
| 3 | Eager dial on destination select | **Yes** — the create sheet should dial | **Phase 0b** (new) | **Yes** — makes the existing spinner reachable |
| 4 | `LabeledTextField` variants | **Leave them** — adopt 7 of 12 | Phase 1b | No |

**The consequence worth stating plainly:** decisions 1 and 3 both change
behaviour, and this plan's whole verification argument rests on phases being
neutral. So decision 3 is not folded into Phase 3 — it becomes **Phase 0b**, its
own commit with its own failing-first test, landing before any extraction.
Decision 1 cannot be isolated that way, because the behaviour change *is* the
canonicalization; instead Phase 2 states exactly which 2 of 8 sites change and
under which inputs, and the phase is described as neutral at 6 and deliberately
changed at 2 rather than as neutral outright.

Decision 2 was checked before being accepted as neutral: the MADR establishes
the two forms are equivalent as written today, so adopting the clone sheet's is
a robustness change with no observable difference — which is why it can sit
inside a neutral phase where decisions 1 and 3 could not.
