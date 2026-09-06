---
status: "accepted"
date: 2026-09-06
decision-makers: [Maintainer]
consulted: []
informed: [Magic Git contributors]
verified: 2026-09-06
---

# Decompose the create-repository sheet, and canonicalize what it duplicates

## Context and Problem Statement

`lib/features/workspace/create_repo_sheet.dart` is **2176 lines**, the largest
feature file in the app. [0032](0032-MADR-recent-and-searchable-forge-namespaces.md)
proposes adding a filtering dropdown with overlay and keyboard navigation to it,
and that proposal already flagged the file's size as an argument for extracting
the namespace control rather than adding in place. This record examines the file
directly and asks two questions:

1. Can it be decomposed into modules, and along what seams?
2. What does it duplicate elsewhere in the app that should be canonicalized?

The answer to both is yes, and the second question turned up more than
redundancy: **the duplication has already drifted**, in four methods, in ways
that are invisible from either copy alone.

> ~~**…and one of the divergences is a live defect.** That changes the argument.
> Deduplication here is not a tidiness exercise; it is the removal of a
> mechanism that has demonstrably produced a bug.~~
> **Corrected 2026-09-06 by executing the plan's own sabotage step.** The
> `_goBack` divergence is **not** a reachable defect — see *Amendments*. The
> duplication findings stand; this sentence overstated what they cost.

### The shape of the monolith

The file is one enum pair, one 15-line widget class, and a single **2068-line
state class** — 95 % of the file — holding **47 methods**.

| Region | Lines | Span | What it is |
| --- | --- | --- | --- |
| Header, enums, widget class | 107 | 1–107 | Imports, `_RemoteMode`, `_SourceMode`, `CreateRepositorySheet` |
| Form state, steps, validation, lifecycle | 342 | 108–449 | 9 controllers, ~19 flags, `WizardStep` list, validators, target resolution |
| **`_submit()`** | **424** | 450–873 | The entire create pipeline, one method |
| Orchestration helpers and pickers | 366 | 874–1239 | Identity, commit, push, origin, register, 4 pickers |
| `build` + widget builders | 912 | 1240–2151 | 21 widget methods |
| Private path helpers | 25 | 2152–2176 | `_dirOf`, `_basenameOf`, `_stripTrailingSlashes` |

Two observations make this tractable rather than daunting:

* **`_submit()` already documents its own seams.** It carries eight
  `// --- … ---` banner comments — *Pre-checks*, *Existing-origin guard*,
  *Step 1: init*, *Identity*, *Step 2: optional initial commit*, *Step 3: wire
  origin*, *Step 4: post-create verification*, *Register + activate*. The author
  identified the phases; they simply are not functions yet. Extraction has a map
  drawn for it.
* **The public surface is two named constructors** —
  `CreateRepositorySheet.connected()` and `.landing()` — plus a
  `@visibleForTesting` duration. **37 offline tests** (`create_repo_sheet_test`
  28, `create_repo_namespace_test` 9, 1611 lines) drive the sheet exclusively
  through that surface via `test/helpers/create_repo_harness.dart`; the string
  `CreateRepositorySheet(` appears **0 times** in `test/`. Any internal
  reorganisation is therefore verifiable end-to-end without touching a single
  assertion — the same property that let 0031's harness extraction be proven
  assertion-neutral.

### Duplication with the clone sheet

`clone_sheet.dart` (1142 lines) is the create sheet's sibling: same wizard, same
destination model, same registration matrix. A method-level comparison of all 47
create-sheet methods against all 30 clone-sheet methods finds **20 sharing a
name**. Six are byte-for-byte identical after whitespace normalisation:

| Method | create | clone | Identical lines |
| --- | --- | --- | --- |
| `_register` | 1128 | 359 | **31** |
| `_browseRemote` | 1222 | 415 | **16** |
| `_pickLocalParent` | 1169 | 401 | **13** |
| `_dirOf` | 2152 | 1064 | **10** |
| `_goNext` | 329 | 172 | **9** |
| `onProvisioningError` | 418 | 251 | **4** |
| | | | **83 total** |

Six more share a name and have **drifted**, which is the more dangerous
condition — a fix applied to one copy does not reach the other:

| Method | create lines | clone lines | Differing | Identical |
| --- | --- | --- | --- | --- |
| `_destinationSection` | 50 | 51 | 3 | **95.0 %** |
| `_goBack` | 7 | 7 | 1 | **85.7 %** |
| `_onDestChanged` | 8 | 12 | 4 | **80.0 %** |
| `_recomputeTarget` | 17 | 19 | 5 | **77.8 %** |
| `initState` | 9 | 13 | 5 | 72.7 % |
| `dispose` | 20 | 15 | 9 | 62.9 % |

### What the drift has cost

> **Amended 2026-09-06.** Item 1 below was disproven by execution; it is kept
> struck through rather than deleted so the record shows what was claimed and
> how it was found wrong. Items 2–4 stand.

Inspecting each divergence individually rather than assuming they are all
intentional:

**1. `_goBack` — a divergence, but ~~a live defect~~ NOT a reachable one.**
The clone sheet guards completion in *two* places: `_goBack` returns early on
`_finished` (`clone_sheet.dart:165`) and the footer disables the button
(`onPressed: _submitting || _finished ? null : _goBack`, `:1018`). The create
sheet guards it in **neither**: `_goBack` tests only `_stepIndex == 0 ||
_submitting` (`create_repo_sheet.dart:322`), and its footer passes
`onPressed: _submitting ? null : _goBack` (`:2129`).

> ~~So **after a successful create, Back is live**. Pressing it decrements the
> step, while `_canSubmit` still returns false because `_finished` is set
> (`:442`) — leaving the user in a wizard they can neither complete nor
> re-submit, escapable only by Close. The clone sheet is immune to the identical
> sequence. This is a genuine pre-existing defect.~~
>
> **Disproven 2026-09-06.** `_submitting` is cleared only in the `finally` at
> `:867`, which runs *after* the `await Future.delayed(successPopDelay)` and the
> `Navigator.pop()`. So for the whole window in which `_finished` is true,
> `_submitting` is true as well, and both existing guards already disable Back.
> The clone sheet's success path (`:345–352`) is structurally identical, so its
> `_finished` guards are defensive redundancy — not a fix that failed to
> propagate. Established by running the test the plan specified against the
> unmodified sheet and watching it **pass**; see *Amendments*.

What remains true, and what the work still turns on: the two `_goBack` bodies
**differ**, so Phase 3b cannot extract them without choosing a winner. The
create sheet's correctness also rests on an **implicit** invariant — that
`_submitting` spans the `_finished` window — which nothing enforces and which
the Phase 4 extraction of `_submit()` could quietly break.

**2. `_recomputeTarget` — a hardening that did not propagate.** The clone sheet
computes into a local `final WorkspaceTarget target` and commits once at the
end. The create sheet assigns `_target` directly and then reads `_target` back
within the same branch. The two are equivalent as written today, but the create
sheet's form is the one that breaks if a future condition is inserted between
the write and the read — and the clone sheet was evidently fixed while the copy
was not.

**3. `_onDestChanged` — a divergence with a visible consequence.** The clone
sheet eagerly calls `ensureProvisioned()` when a destination resolving to
`sshProvision` is selected; the create sheet does not. Yet the create sheet's
`_destinationSection` renders the `provisioning` "Connecting…" spinner
(`:1372-1386`) — a spinner for a state its own destination control never
initiates. ~~so it can only appear once submit begins.~~ *(Corrected
2026-09-06: the spinner is also reachable from the two Browse buttons, which
call `ensureProvisioned()` at `:1203` and `:1223` — submit at `:457` is not the
only trigger. The destination control remains the one place that does not reach
it.)* Whether the eager dial is wanted in the create flow is a product question;
that the two sheets answer it differently by accident is not.

**4. `_destinationSection` — pure parameterisation.** All three differing lines
are hint wording: "The repository is **created** on…" versus "The repository is
**cloned** onto…". Fifty lines of identical widget code differing by a verb.

### Duplication across the wider application

**`_basename` is implemented eight times**, in two behaviourally distinct
families:

* *Family A* — split on `/`, drop empty segments, take the last, fall back to
  the input: `core/storage/saved_local_repo.dart:137`,
  `core/storage/saved_connection.dart:112`,
  `features/tabs/saved_workspaces_sheet.dart:293`,
  `features/tabs/tab_strip.dart:14`,
  `features/switcher/current_repo_indicator.dart:18`,
  `features/switcher/connection_switcher.dart:28`.
* *Family B* — strip trailing slash(es), then `lastIndexOf('/')`:
  `features/dnd/drag_item.dart:70` (strips **one**),
  `features/workspace/create_repo_sheet.dart:2163` (strips **all**).

Executed against the three implementations verbatim, they agree on every
well-formed path and diverge on three inputs:

| Input | Family A (×6) | `drag_item` | `create_repo_sheet` |
| --- | --- | --- | --- |
| `a/b//` | `b` | *(empty)* | `b` |
| `/` | `/` | *(empty)* | *(empty)* |
| `//` | `//` | *(empty)* | *(empty)* |

A path ending in a doubled slash renders an empty drag label; a root path
renders as `/` in the tab strip and as empty in the create sheet. These are
latent rather than reported — none of the three inputs is common — but they are
three different answers to one question.

**`_stripTrailingSlashes` exists twice under the same name, differing by one
character.** `HostFsService` (`core/git/host_fs_service.dart:186`) loops while
`end > 0`; the create sheet (`:2169`) loops while `end > 1`. Verified:

| Input | `HostFsService` | `create_repo_sheet` |
| --- | --- | --- |
| `/` | *(empty)* | `/` |
| `//` | *(empty)* | `/` |
| `///` | *(empty)* | `/` |
| `/a/`, `a//`, `` | identical | identical |

The create sheet's version deliberately preserves the filesystem root; the
service's does not. **A canonicalization that merges these on name alone would
silently change one call site's behaviour** — this pair must be unified on
behaviour, with the root case pinned by a test, or kept as two explicitly named
functions.

In total, `lib/` carries **13 private path-helper definitions**.

### Canonical homes that already exist and are not used

The most striking finding is that several targets are already written, already
imported, and simply bypassed:

* **`WizardReviewRow`** lives in `features/workspace/wizard.dart:127` — a file
  `create_repo_sheet.dart` already imports. The create sheet instead defines a
  private `_reviewRow` (`:2063`) whose body is **identical** to it. The clone
  sheet uses the shared widget at **5** call sites; the create sheet uses it
  **0** times. Every other wizard component (`WizardStep`,
  `WizardStepIndicator`, `WizardStepIntro`, `WizardProgressBar`, `WizardHint`)
  *is* adopted by both. This is one missed adoption, not a systemic gap.
* **`LabeledTextField`** (`features/common/labeled_text_field.dart:7`) renders
  exactly the block the create sheet hand-rolls: a `caption1` label, a 4 px gap,
  and a `MacosTextField` carrying `kAppPlaceholderStyle`,
  `kAppTextFieldDecoration` and `kAppTextFieldFocusedDecoration`. The create
  sheet writes that block out **12 times** (matching its 12 `MacosTextField`
  instances and 12 `kAppTextFieldDecoration` references) while importing
  `field_styles.dart` for the constants. It is used today by the connection
  form, the worktree sheet, the switcher's edit sheets and — via
  `ForgeSheetField` — all three forge create forms.
* **`workspace_registration.dart`** is the established precedent, and its own
  library comment states the convention this record extends: the clone and
  create sheets "share one registration matrix … **Kept as standalone functions
  (not sheet methods) so there is exactly one implementation to reason
  about.**" The functions are shared; the 31-line `switch` that dispatches to
  them is still duplicated in both sheets.
* **`WorkspaceProvisioning`** (`workspace_provisioning.dart`) shows the mixin
  form of the same idea, and both sheets already use it.

### What is not duplication

Reported for accuracy, because two candidates look like duplication and are not:

* **`ForgeSheetToggle` vs `WorkspaceToggleRow`.** The forge version renders a
  `MacosSwitch`; the workspace version renders a coloured `ToolIconButton` with
  on/off icons. Different affordances, not two copies of one. Whether the app
  should have two toggle idioms is a design question, and it is **out of scope**
  for this record.
* **Two shared-widget libraries.** `features/workspace/{wizard,workspace_widgets}.dart`
  serves the clone and create sheets; `features/forge/forge_create_sheet_widgets.dart`
  serves the MR, PR and issue forms. They are not rival copies — they overlap
  only at `LabeledTextField`, which the forge library already delegates to.

## Decision Drivers

* **Deduplicate what has drifted, first.** Four methods diverged because two
  copies were maintained independently, and no copy shows it. Ranking the work
  by "which duplicate has already diverged" targets real risk rather than line
  count. *(Amended 2026-09-06: this driver originally cited the `_goBack`
  divergence as a shipped bug. It is not one — but the divergences are still
  real, and `_goBack`'s must be resolved before Phase 3b can extract it.)*
* **A refactor must be provably behaviour-neutral.** 37 offline tests reach the
  sheet only through two constructors. That is the instrument; it only counts if
  the tests are not edited alongside the code they verify.
* **Never smuggle a fix into a refactor.** A behaviour change hidden inside a
  1000-line move cannot be reviewed, and it destroys the neutrality argument
  that makes the move safe.
* **Canonicalize on behaviour, not on name.** The two `_stripTrailingSlashes`
  functions prove the hazard: identical names, different contracts, and a
  careless merge silently breaks a call site.
* **Prefer the conventions already in the tree.** Standalone functions
  (`workspace_registration.dart`), a mixin (`workspace_provisioning.dart`), and
  shared widgets (`wizard.dart`) are three established forms. Adopt them rather
  than inventing a fourth.
* **Split along seams the code already names.** `_submit()`'s eight banner
  comments and the wizard's step list are the file's own decomposition; using
  them keeps the diff legible.
* **Do not let scope escape.** This touches the two largest workspace files and
  eight call sites across five features. It has to land in reviewable pieces,
  each independently verifiable.

## Considered Options

**Decision 1 — how far to decompose the sheet.**

* **1A. Leave it.** Add 0032's dropdown in place.
* **1B. Widget-only split.** Extract the step bodies into widgets; leave state
  and `_submit()` where they are.
* **1C. Behaviour-only split.** Extract `_submit()`'s eight phases into a
  testable orchestrator; leave the widget tree intact.
* **1D. Both**, phased: orchestrator first, then step widgets, with the shared
  form state passed explicitly.

**Decision 2 — where cross-sheet code goes.**

* **2A. Standalone functions** in `features/workspace/`, extending the
  `workspace_registration.dart` convention.
* **2B. A widened `WorkspaceProvisioning`-style mixin** carrying pickers,
  navigation and destination.
* **2C. A shared base `State` class** both sheets extend.

**Decision 3 — the path helpers.**

* **3A. One canonical module** (`core/utils/posix_path.dart`) with `basename`,
  `dirname` and `stripTrailingSlashes`, replacing all 13 private definitions.
* **3B. Canonicalize only within `features/workspace/`.**
* **3C. Leave them.**

**Decision 4 — the `_goBack` defect.**

* **4A. Fix it first**, as its own commit, before any extraction.
* **4B. Fix it as part of the extraction.**
* **4C. Leave it; record it.**

**Decision 5 — proving neutrality.**

* **5A. The existing 37 tests, unedited**, plus a mechanical check that
  assertion counts are unchanged.
* **5B. New tests written against the new modules.**
* **5C. Both** — existing suite unedited as the neutrality proof, new unit tests
  added afterwards for the newly reachable seams.

## Decision Outcome

Chosen options: **1D**, **2A**, **3A**, **4A**, **5C** — because the file's own
comments and test surface already define the seams and the instrument, the
codebase already has the conventions and two of the target modules, and the
drift that motivates the work has produced a defect that must be fixed on its
own before anything moves.

Ordered so that each piece is separately reviewable and separately revertible:

* **Phase 0 — fix `_goBack`, alone.** *(Amended 2026-09-06: now Phase 0a;
  Phase 0b carries the eager-dial change — see Amendments.)* Add the
  `_finished` guard to
  `create_repo_sheet.dart:322` and its footer, matching `clone_sheet.dart:165`
  and `:1018`, with a regression test that completes a create and asserts Back
  is inert. Nothing else in the commit. This is a behaviour change and must not
  be inside a refactor; fixing it first also means every later phase can claim
  neutrality against a correct baseline. ~~Per the deviation rule, the
  remaining divergences (`_recomputeTarget`, `_onDestChanged`) are **raised,
  not fixed**: the first is a latent hardening and the second is a product
  question about whether the create flow should dial eagerly. Both need a
  decision before code.~~
  > **Amended 2026-09-06 — both decided.** `_recomputeTarget` adopts the clone
  > sheet's form (behaviour-neutral, so it stays inside the extraction phase);
  > the create flow **should** dial eagerly — a behaviour change, and therefore
  > its own commit, **Phase 0b**, before any extraction. See *Amendments*.
* **Phase 1 — adopt what already exists.** Delete `_reviewRow` for
  `WizardReviewRow`; extend `LabeledTextField` with an optional hint slot and an
  optional error-decoration override, then adopt it across the sheet's 12
  hand-rolled blocks. Both are mechanical, both shrink the file, neither moves
  logic. The `LabeledTextField` extension is the only new API, and it is small
  and additive — the sheet's two validating fields (`:1596-1626`) swap
  `kAppTextFieldDecoration` for `kAppTextFieldErrorDecoration` on invalid
  input, which the current widget cannot express.
* **Phase 2 — canonicalize the path helpers** (3A). One module with `basename`,
  `dirname` and `stripTrailingSlashes`, replacing 13 private definitions across
  8 files. **The two `stripTrailingSlashes` contracts are unified deliberately,
  not by name**: pick the root-preserving or root-collapsing behaviour, pin `/`,
  `//`, `a/b//` and `""` in tests, and check each of the 8 `basename` call sites
  against the chosen family before switching it. This phase carries the most
  blast radius per line and the least conceptual difficulty.
* **Phase 3 — extract the shared sheet code as standalone functions** (2A):
  the `_register` dispatcher (31 identical lines), `pickLocalDirectory` and
  `browseRemoteDirectory` (29 identical lines), wizard navigation
  (`_goBack`/`_goNext`/`_activeSteps`, now with one `_finished` contract), and a
  `WorkspaceDestinationSection` widget parameterised by the verb that is its
  only difference. Standalone functions over a widened mixin or a shared base
  class because that is what `workspace_registration.dart` already established
  and what its comment argues for: one implementation to reason about, with no
  inheritance coupling between two sheets that are only 60 % alike.
* **Phase 4 — extract the create pipeline** (1C half of 1D). `_submit()`'s eight
  banner-marked phases become an orchestrator that takes an executor, a log sink
  and a plain settings record, and returns a result — no `BuildContext`, no
  `setState`. This is the phase that buys the most: 424 lines of sequencing
  currently reachable only by pumping a widget become directly unit-testable,
  which is precisely the "seam" failure shape
  [0030](0030-MADR-test-coverage-gaps-are-shaped-not-sized.md) names.
* **Phase 5 — extract the step bodies** (1B half of 1D) into
  `create_repo_steps/`, each taking the form state it needs. This is where
  0032's namespace control lands, as its own widget, rather than as more lines
  in a 2176-line file.

Neutrality is proven the way 0031's harness extraction was (5C): **Phases 1–5
run the existing 37 tests unedited**, and each phase additionally shows that
`expect(` and `testWidgets(` counts across `test/` are unchanged, so the suite
cannot have been weakened to accommodate the move. New unit tests are added only
*after* a phase lands, against seams that phase newly exposed — the orchestrator
above all. Phase 0 is the exception: it changes behaviour, so it adds a test
that fails before it and passes after.

### Consequences

* Good, because it removes the mechanism that produced the `_goBack` defect
  rather than only the defect.
* Good, because 424 lines of create-pipeline sequencing become testable without
  a widget pump, closing a seam gap of exactly the kind 0030 catalogued.
* Good, because 83 byte-identical lines and ~30 more drifted ones stop being
  maintained twice, and 13 path helpers collapse to 3.
* Good, because 0032's dropdown gets somewhere to live that is not the bottom of
  a 2176-line file.
* Good, because the phases are independently revertible: any one can be dropped
  without stranding the others.
* Bad, because it touches the two largest workspace files plus 8 call sites in 5
  features, and pure refactors carry risk without delivering user-visible value.
* Bad, because Phase 2 has real blast radius: `basename` feeds tab titles, the
  switcher, drag labels and saved-repo display names, and the two
  `stripTrailingSlashes` contracts genuinely differ. It is the phase most likely
  to produce a subtle regression and the one whose tests matter most.
* Bad, because extracting `_submit()` means threading ~19 state flags into a
  settings record; done carelessly that is a second copy of the form state
  rather than a boundary.
* Neutral, because the file stays large even after this: the create flow is
  genuinely the app's most complex form, and the goal is legible modules, not a
  line-count target.
* Neutral, because `clone_sheet.dart` benefits roughly as much as the create
  sheet, which is right — but it doubles the review surface of Phases 3 and 4.

### Confirmation

* **Phase 0a:** a widget test driving a create to completion and asserting the
  Back button is disabled and `_goBack` is inert. ~~Seen to fail against the
  current code before the guard is added.~~ *(Amended 2026-09-06: it **passes**
  against the current code. It is kept as a pin on an invariant that is
  currently implicit, not as a regression test for a fixed bug — and the
  execution record must say so rather than claiming a failing-first run.)*
* **Phases 1–5:** `flutter test` green with `test/create_repo_sheet_test.dart`,
  `test/create_repo_namespace_test.dart` and
  `test/helpers/create_repo_harness.dart` **unedited**, plus a diff check that
  `expect(` and `testWidgets(` counts across `test/` are unchanged.
* **Phase 2:** unit tests pinning `basename`, `dirname` and
  `stripTrailingSlashes` on `/`, `//`, `///`, `a/b//`, `/a/b`, `a//b` and `""`
  before any call site is switched, and a per-call-site review recording which
  of the two `basename` families each of the 8 sites was on.
* **Phase 4:** orchestrator unit tests over a fake `CommandExecutor` covering
  the eight phases, including the existing-origin guard and the
  warnings-not-failures paths — reachable for the first time without a widget.
* `flutter analyze` clean on first pass at every phase, per the repo's strict
  analyzer settings.
* **Every new check is to be run against a deliberately broken input and seen to
  fail before it is relied on**, against scratch copies rather than by dirtying
  the tree.
* The `live-forge` test (`create_repo_wire_live_test.dart`) is **not** part of
  routine confirmation. It is mutating and maintainer-run only; a single
  explicitly-requested run after Phase 4 is the appropriate check that the
  extracted pipeline still works against a real forge.

## Pros and Cons of the Options

### 1A. Leave it

* Good, because it costs nothing and risks nothing today.
* Bad, because the drift mechanism stays live: the next fix applied to one sheet
  still misses the other, which is how `_goBack` happened.
* Bad, because 0032's dropdown makes the file bigger, and the marginal cost of
  every later change to it keeps rising.

### 1B. Widget-only split

* Good, because widget extraction is the lowest-risk kind — the tests pump the
  same tree.
* Good, because it addresses the 912-line build region, the largest single
  block.
* Bad, because it leaves `_submit()`'s 424 lines untestable except through a
  widget pump, which is the more valuable half.

### 1C. Behaviour-only split

* Good, because it converts the least-testable code into the most-testable, and
  `_submit()`'s own banner comments define the boundaries.
* Good, because it is invisible to the widget tests, so neutrality is easy to
  argue.
* Bad, because the file stays over 1700 lines and the build region is untouched,
  so 0032 still has nowhere clean to land.

### 1D. Both, phased

* Good, because it addresses both halves and each phase is separately
  reviewable and revertible.
* Good, because ordering behaviour before widgets means the riskiest extraction
  happens while the widget tree — and therefore the test surface — is still
  exactly as the tests found it.
* Bad, because it is the largest total scope, and a partially-executed plan
  leaves the codebase mid-migration with two idioms in the same file.

### 2A. Standalone functions

* Good, because `workspace_registration.dart` already does this and its comment
  argues for it explicitly.
* Good, because a plain function is directly unit-testable and imposes no
  inheritance relationship.
* Neutral, because state that the function needs must be passed as arguments,
  which makes the coupling visible — a cost that is also the point.
* Bad, because functions needing `setState` and `mounted` must return a value
  for the caller to apply, so the pickers grow a small result type.

### 2B. A widened mixin

* Good, because `setState`/`mounted`/`context` are in scope, so the picker
  bodies move verbatim.
* Good, because both sheets already mix in `WorkspaceProvisioning`.
* Bad, because a mixin holding navigation, pickers and destination state becomes
  the shared base class of 2C by another name, with the same implicit coupling
  and none of its clarity.

### 2C. A shared base State class

* Good, because it removes the most duplication in the fewest lines.
* Bad, because the sheets are only ~60 % alike; the base class would accrete
  conditionals for the differences and become the thing it replaced.
* Bad, because it couples two sheets' lifecycles, so a change for one is a risk
  to the other — the same failure mode as copy-paste, relocated.

### 3A. One canonical path module

* Good, because it collapses 13 definitions to 3 and gives the divergent
  behaviours one documented contract.
* Good, because these are pure functions — the easiest possible things to pin
  with tests.
* Bad, because it is the widest blast radius in the plan: 8 files across 5
  features, several on hot display paths.
* Bad, because it forces a decision on the root-path contract that nobody has
  had to make until now.

### 3B. Canonicalize only within `features/workspace/`

* Good, because it is small and touches only files this record is already
  changing.
* Bad, because it leaves 6 of the 8 `basename` copies in place, so the app still
  has two answers for `/` — it fixes the symptom in one neighbourhood.

### 3C. Leave the path helpers

* Good, because none of the divergences is a reported bug.
* Bad, because they are three different answers to one question, sitting in code
  that formats what the user sees, waiting for the first malformed path.

### 4A. Fix `_goBack` first, alone

* Good, because a behaviour change gets its own reviewable commit and its own
  failing-first test.
* Good, because every later phase then claims neutrality against a correct
  baseline rather than preserving a bug on purpose.
* Neutral, because it slightly delays the refactor.

### 4B. Fix it during the extraction

* Good, because it is one fewer commit.
* Bad, because it destroys the neutrality argument: a diff that both moves 1000
  lines and changes behaviour cannot be reviewed for either.

### 4C. Leave it, recorded

* Good, because it keeps this record purely structural.
* Bad, because a known, reproducible dead-end in a shipping wizard is not
  something to file and walk past, and the fix is one condition.

### 5A. Existing tests, unedited

* Good, because an unedited suite is the strongest available neutrality
  evidence, and it is already written and already passing.
* Bad, because it proves only that nothing observable changed — it does not
  exercise the new modules' seams.

### 5B. New tests against the new modules

* Good, because it covers the seams the extraction creates, which is where the
  new risk lives.
* Bad, because tests written alongside a refactor codify whatever the refactor
  did, including its mistakes; alone, they prove nothing about neutrality.

### 5C. Both

* Good, because the two do different jobs: the old suite proves nothing changed,
  the new tests cover what became reachable.
* Good, because adding the new tests *after* a phase lands keeps the neutrality
  evidence uncontaminated.
* Bad, because it is more total work than either alone.

## Amendments

### 2026-09-06 — the `_goBack` "live defect" was disproven by executing the plan

**How it was found.** Phase 0a of the plan required the fix's test to be written
first and seen to fail against the unmodified sheet. It was. It **passed** —
which is the outcome that invalidates the phase rather than confirming it.

**Why the original claim was wrong.** This record reasoned from the divergence
(the clone sheet guards `_finished` in `_goBack` and its footer; the create sheet
guards it in neither) to a reachable defect, without checking whether something
else already covered the same window. Something does: `_submitting` is cleared
only in the `finally` at `create_repo_sheet.dart:867`, which runs *after* the
`await Future.delayed(successPopDelay)` and the `Navigator.pop()`. Throughout the
window in which `_finished` is true, `_submitting` is true too, so
`_goBack:322` and the footer at `:2129` both already refuse. The clone sheet's
success path (`clone_sheet.dart:345–352`) is structurally identical, so its
`_finished` guards are belt-and-braces, not a propagated fix.

**A caution the experiment itself taught.** The test failed twice before it was
valid — first on a `RenderFlex overflowed by 22 pixels` from the "Creating…"
footer (which `pumpCreate` drains and a raw `tap`+`pump` does not), then on
`A Timer is still pending` from the success-pop delay. Either failure would have
been mistaken for the predicted one and recorded as "seen to fail". **A negative
result is only evidence once the failure has been read, not merely observed.**

**What changed as a result** (decided by the maintainer, 2026-09-06 — Option A):

* Phase 0a is **reframed, not dropped**. It is no longer a defect fix. It applies
  the clone sheet's guard to the create sheet as an **alignment** change, so the
  two `_goBack` bodies become byte-identical and Phase 3b's extraction is a pure
  move rather than a choice between two behaviours.
* The test is **kept**, as a pin on an invariant that is otherwise implicit:
  nothing enforces that `_submitting` spans the `_finished` window, and Phase 4's
  extraction of `_submit()` is exactly the kind of change that could break it
  silently. It passes before and after, and the execution record must say so.
* The commit must not claim a fix.

**What survives unchanged.** Every duplication finding in this record was
established by execution rather than inspection and still stands: the 83
byte-identical lines across 6 methods, the four drifted methods and their
percentages, the 8 `basename` copies in 2 families (verified to disagree on
`a/b//`, `/` and `//`), and the two `stripTrailingSlashes` contracts with the
`removeDirGuarded` root guard depending on one of them. Phase 0b and Phases 1–5
are unaffected, as are all four decisions recorded above.

### 2026-09-06 — the four questions this record left open are answered

The plan raised four decisions this record deferred. The maintainer resolved all
four. Recorded here because two of them change what this record asserted.

| # | Question | Decision |
| --- | --- | --- |
| 1 | Which `basename` family becomes canonical | **Family A** — split on `/`, drop empty segments, take the last |
| 2 | Whether `_recomputeTarget` adopts the clone sheet's form | **Yes** |
| 3 | Whether the create flow should dial eagerly on destination select | **Yes** |
| 4 | Whether `LabeledTextField` gains variants to cover all 12 field blocks | **No** — adopt the 7 that fit, leave 5 hand-rolled |

**What this changes about the decision above.** The Decision Outcome said the
`_onDestChanged` divergence was "raised, not fixed" and needed a decision before
code. It now has one, and the answer makes it a **behaviour change**: the create
sheet will provision eagerly, which makes the `provisioning` spinner it already
renders (`create_repo_sheet.dart:1372–1386`) reachable from the destination
control for the first time, rather than only once submit begins.

That does not belong in an extraction phase. The argument this record already
makes for isolating the `_goBack` fix — a diff that both moves code and changes
behaviour can be reviewed for neither — applies unchanged, so the eager dial
becomes its own commit ahead of the refactor. The phase list is therefore **0a,
0b, 1, 2, 3, 4, 5**: seven commits, not six.

**What this changes about the neutrality claim.** Decision 1 also changes
behaviour, at exactly 2 of the 8 `basename` sites, and unlike decision 3 it
cannot be isolated — the behaviour change *is* the canonicalization. So "phases
1–5 are behaviour-neutral" narrows to "phases 1 and 3–5 are neutral; phase 2 is
neutral at 6 of 8 sites and deliberately changes 2". The plan names those two
sites, the inputs under which they differ, and assesses each: `drag_item.dart:70`
gains behaviour matching its own doc comment (which says it "tolerates a trailing
slash", singular), while the create sheet's two call sites receive paths from the
native picker and from `HostFsService.joinPath`, neither of which can carry a
trailing slash — so the change there is a contract change rather than an observed
one, to be confirmed by inspection during execution.

Decision 2 was checked rather than assumed before being called neutral: this
record already establishes the two `_recomputeTarget` forms are equivalent as
written, so adopting the clone sheet's is a robustness change with no observable
difference — which is why it can sit inside a neutral phase where decisions 1
and 3 could not.

## More Information

* [0032-MADR-recent-and-searchable-forge-namespaces.md](0032-MADR-recent-and-searchable-forge-namespaces.md)
  — proposes a filtering dropdown for this sheet and identifies its size as an
  argument for extraction; Phase 5 here is where that control should land.
* [0030-MADR-test-coverage-gaps-are-shaped-not-sized.md](0030-MADR-test-coverage-gaps-are-shaped-not-sized.md)
  — names the seam-shaped coverage gap that `_submit()` is a textbook instance
  of, and establishes that composition is not behaviour.
* [0031-PLAN-forge-namespace-on-create.md](0031-PLAN-forge-namespace-on-create.md)
  — the harness extraction whose assertion-neutrality argument (reverse the
  renames, diff against HEAD, compare `expect(` counts) is the method Phases 1–5
  reuse.
* Code — the monolith: `lib/features/workspace/create_repo_sheet.dart`
  (`_submit` 450–873 with banners at 515/579/621/647/658/686/816/841;
  `_goBack` 321; `_reviewRow` 2063; path helpers 2152–2176; validating fields
  1596–1626).
* Code — the sibling: `lib/features/workspace/clone_sheet.dart`
  (`_register` 359, `_browseRemote` 415, `_pickLocalParent` 401, `_goBack` 164,
  footer Back 1018, `_destinationSection` 516, `_dirOf` 1064).
* Code — existing canonical homes: `features/workspace/wizard.dart:127`
  (`WizardReviewRow`), `features/common/labeled_text_field.dart:7`,
  `features/workspace/workspace_registration.dart` (the standalone-function
  convention), `features/workspace/workspace_provisioning.dart` (the mixin
  form), `features/workspace/workspace_targets.dart`, `workspace_widgets.dart`.
* Code — the eight `basename` copies: `core/storage/saved_local_repo.dart:137`,
  `core/storage/saved_connection.dart:112`,
  `features/tabs/saved_workspaces_sheet.dart:293`,
  `features/tabs/tab_strip.dart:14`,
  `features/switcher/current_repo_indicator.dart:18`,
  `features/switcher/connection_switcher.dart:28`,
  `features/dnd/drag_item.dart:70`,
  `features/workspace/create_repo_sheet.dart:2163`; and the two
  `stripTrailingSlashes`: `core/git/host_fs_service.dart:186`,
  `features/workspace/create_repo_sheet.dart:2169`.
* Method-level comparison and the divergence tables were produced on 2026-09-06
  by extracting every method from both sheets by brace matching, normalising
  whitespace, and diffing; the `basename` and `stripTrailingSlashes` tables were
  produced by executing the implementations verbatim rather than by reading
  them.
