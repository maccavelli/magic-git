---
status: "proposed"
date: 2026-09-05
associated-madr: "0030-MADR-test-coverage-gaps-are-shaped-not-sized.md"
---

# Close the four failure shapes, in risk order

Associated MADR: [0030-MADR-test-coverage-gaps-are-shaped-not-sized.md](0030-MADR-test-coverage-gaps-are-shaped-not-sized.md)

## Goal

Land the eight proposals in MADR 0030 as tests that have each been **seen to
fail**, targeting the four failure shapes that produced five defects in one
session — the seam, composition-asserted-behaviour-assumed, parity, and the
in-flight state.

**Success is not a coverage number.** The MADR recommends against adopting one,
and this plan does not set one. Success is: each shape has a check that fails
when the shape recurs, and the two risk-weighted uncovered paths (a file written
to a host, a repository mutated by undo) have behavioural tests.

## Scope

**In scope**

* Eight test artifacts (T1.1–T1.3, T2.4–T2.6, T3.7–T3.8), each red-then-green.
* Whatever minimal production change a parity harness forces, **only when the
  harness proves an implementation does not satisfy a contract it claims**.

**Out of scope**

* Any coverage target, and any test written to raise a percentage.
* Mutation-testing tooling (MADR: rejected — Dart tooling immature, runtime
  budget).
* Refactoring implementations to be more alike for its own sake. If the parity
  harness surfaces a *deliberate* difference, that is documented, not erased.
* Behaviour changes to undo, connect, or upload beyond what a test needs.

## Preconditions

```sh
flutter --version | head -1          # must equal FLUTTER_VERSION (3.47.2)
flutter pub get --enforce-lockfile   # "Got dependencies!"
git status --short                   # empty
flutter analyze                      # No issues found!
flutter test                         # 3508 passing, 2 skipped, 0 failing
```

Any deviation from **3508 / 2 / 0**: stop and prompt — the baseline moved.

## Baseline, recorded 2026-09-05

Retaken in Phase 9 and compared, **including figures that do not move**.

| measure | value |
|---|---|
| line coverage | 81.4 % (29,065 / 35,691) |
| files with zero coverage (>40 lines) | 0 |
| `ProxyCommandExecutor` | 60.0 % (39/65), 1 test file |
| `ScopedCommandExecutor` | 40.9 % (9/22), 3 test files |
| `ActivityCommandExecutor` | 66.7 % (12/18), 1 test file |
| `SSHCommandExecutor` / `LocalCommandExecutor` | 82.9 % / 85.0 %, 126 / 34 test files |
| `ProxyCommandExecutor.uploadBytes()` | 18 of 26 lines uncovered |
| `_undoGitOperation()` + `_redoGitOperation()` | 69 uncovered |
| `connect()` + `connectLocal()` | 68 uncovered |

## Implementation Steps

Ordered so the cheap enforcement lands first and the phase most likely to
surface a real defect (Phase 3) lands after the scans that would catch its
fallout.

---

### Phase 1 — T3.7: widen the in-flight render guard

**Files.** `test/refresh_no_flash_test.dart`; whichever render sites it flags.

`refresh_no_flash_test`'s scan covers `.when()` on providers derived from
`repoSnapshotProvider`. **Seven provider families derive from another provider's
`.future`** (15 sites in `app_providers.dart`): `forgeAuthProvider`,
`forgeProvider`, `originRemoteUrlProvider`, `refsProvider`, `remotesProvider`,
`repoLayoutProvider`, `repoSnapshotProvider`. Every one turns a refresh into a
**reload** for its dependents, which is defect 3's condition.

Generalise the scan's derived-set discovery from "references
`repoSnapshotProvider`" to "references any `\w+Provider\(...\)\.future`".

**1a.** Run the widened scan and record what it flags, verbatim.

**1b.** For each flagged site, decide and record one of:
* add `skipLoadingOnReload: true` — the site should keep its rows; or
* leave it and write down why — some panes *should* show a spinner (a repo
  switch is not a refresh).

> **Not every flag is a bug.** A flag that is correct-as-is gets a comment
> saying so, so the next reader does not "fix" it.

**Required red:** the widened scan against today's tree must name at least one
site beyond the two already fixed, or the widening bought nothing and this phase
is recorded as such rather than declared done.

**Acceptance.** Scan green; every flagged site resolved with a recorded reason;
suite +0 tests (the scan already exists), analyzer clean. **Commit.**

---

### Phase 2 — T1.2: a parity scan for multi-implementation abstractions

**Files.** new `test/implementation_parity_test.dart`.

Exactly two abstractions have multiple implementations:

| abstraction | implementations |
|---|---|
| `CommandExecutor` | `SSHCommandExecutor`, `LocalCommandExecutor`, `ScopedCommandExecutor`, `ActivityCommandExecutor`, `ProxyCommandExecutor` |
| `CommandStreamHandle` | `_SshSessionStreamHandle`, `_ActivityStreamHandle`, `_LocalActivityStreamHandle`, `_ProcessStreamHandle` (all private) |

The scan reads `lib/` for `implements <Abstraction>`, groups by abstraction, and
for each group with >1 implementation requires every **public** implementation
to be named by at least one test file. Private implementations are exempt by
construction (a test cannot name them) and the scan records that rather than
silently skipping.

**2a. Negative test.** A fixture directory with two implementations of one
abstraction, one referenced by a fixture "test" and one not; the scan reports
the second.
**Required red:** the scan passes with an unreferenced sibling before the check
exists.

**2b.** Run against the real tree. `ProxyCommandExecutor` (1 file),
`ActivityCommandExecutor` (1) and `ScopedCommandExecutor` (3) are all *named*
today, so the scan is expected to be **green on first run against `lib/`** —
which is why 2a exists, and why this phase's value is the fixture test, not the
live run.

> **Stated plainly:** a name-counting scan is weak. It catches "no test mentions
> this implementation at all", which is the condition that produced defect 4 in
> the watch services, and nothing stronger. Phase 3 is what actually tests
> parity.

**Acceptance.** 2a red then green; live run green with private impls listed as
exempt; suite +1. **Commit.**

---

### Phase 3 — T1.1: the executor parity harness

**Files.** new `test/executor_contract_test.dart`; possibly
`lib/core/exec/*.dart` **only if** the harness proves a claimed-contract
violation.

One shared test body, run against every `CommandExecutor` implementation that
can be constructed in-process. The contract, taken from the abstract class and
from `AGENTS.md`'s transport rules:

| # | contract | why it is in the harness |
|---|---|---|
| C1 | `execute` takes `List<String>` argv and never builds a shell string | `AGENTS.md`: `ShellEscaper` is the injection defense; a wrapper that re-joins would defeat it |
| C2 | a non-zero exit is reported as a result, not swallowed | 0022 M10's silent-success trap |
| C3 | output byte budgets bound a large stdout | `command_drain.dart` applies to one-shot paths |
| C4 | `uploadBytes` refuses when its required routing information is absent | `ProxyCommandExecutor` enforces this; do the others? |
| C5 | `resolvedBinaryPath` / `configureEnvironment` / `resetEnvironment` round-trip | wrappers must delegate, not drop |
| C6 | cancelling a stream handle releases its resources | the orphan class of defect |

Implementations are driven against a **fake transport** (a fake `SSHClient`
manager, a fake platform channel for the proxy, a scratch directory for the
local executor). Where an implementation genuinely cannot satisfy a row — e.g.
`ProxyCommandExecutor.executeStream` throws `UnsupportedError` by design — the
harness asserts **that documented refusal**, which is itself parity: a
deliberate difference, tested.

**3a. Required red — and this phase is not accepted without it.**

> A parity harness that passes against every implementation on its first run has
> established **nothing**. It has shown only that it asserts nothing the
> implementations do not already share. The harness must be observed failing
> against at least one implementation — most likely `ProxyCommandExecutor` at
> 60 % coverage or `ScopedCommandExecutor` at 40.9 % — before the phase closes.
>
> If it genuinely passes everywhere on the first run, that is a **deviation**:
> stop, and either strengthen the contract rows until one fails, or record that
> parity was already sound and the harness's value is regression-prevention
> only. Do not close the phase on a first-run pass.

**3b.** Any production change made to satisfy a contract row is recorded as a
deviation with the row, the failure, and the fix — a behaviour change, not a
test change.

**Acceptance.** Harness runs against ≥4 implementations; red observed and
recorded verbatim; suite +N; analyzer clean. **Commit.**

---

### Phase 4 — T1.3: ordering invariants at host seams

**Files.** new `test/host_seam_ordering_test.dart`.

Defect 2 was an ordering property between a service and the script it launches:
the lease was stamped *after* the script that checks for it. That test now
exists for the watcher. Three more seams have the same shape:

1. **Scope env before the command that needs it.** A scoped (dotfiles) repo's
   `GIT_DIR`/`GIT_WORK_TREE` must be applied to the command, not after it —
   `ScopedCommandExecutor`, 40.9 % covered.
2. **Pid recorded before the process can be signalled.** The sweep reads a pid
   file; a watcher that is signalled before it records is unreclaimable — the
   permanent-orphan condition of 0027 amendment 0027.1.
3. **Forge auth before the first forge read.** `connect()` logs in and then
   reads; `forgeAuthPending` exists because those race (`repo_status_view.dart`
   treats a "not logged in" error as in-progress login).

Each is asserted by recording the **order of operations** a fake executor
observes, as `watch_lease_identity_test` does.

**Required red per invariant:** swap the two operations in the production path
and observe the test name the inversion.

**Acceptance.** Three tests red then green; suite +3. **Commit.**

---

### Phase 5 — T2.4: `ProxyCommandExecutor.uploadBytes()`

**Files.** new `test/proxy_upload_bytes_test.dart`.

18 of its 26 lines are uncovered, and it is the path by which **a pop-out editor
writes a file back to the host**. Assertions:

* bytes cross the relay as `Uint8List` and arrive byte-identical, including a
  payload containing **NUL and invalid UTF-8** — `AGENTS.md` records that the
  native codec truncates strings at NUL, and `exec_proxy_codec_test` covers the
  codec but not this call path;
* a missing/empty `routingRepo` throws `ProxyExecuteException` before any
  channel call (`proxy_command_executor.dart:255-260`);
* a `PlatformException` from the main window surfaces as `ProxyExecuteException`
  with the message, not a silent success;
* a `MissingPluginException` (main window gone) surfaces likewise;
* the outstanding-request bookkeeping (`_outstanding` add/remove, probe
  start/stop) is balanced on both the success and failure paths — a leak here
  keeps a liveness probe pinging a dead channel.

**Required red:** each assertion demonstrated against a deliberately broken fake
(bytes re-encoded as `String`; the guard removed; the exception swallowed).

**Acceptance.** Tests red then green; `uploadBytes` uncovered lines → 0; suite
+N. **Commit.**

---

### Phase 6 — T2.5: undo/redo shell wiring

**Files.** new `test/app_shell_undo_test.dart`.

The undo *logic* is well covered — `undo_journal.dart` 100 %,
`undo_types.dart` 97 %, `undo_controller.dart` 88.2 %, seven test files. **The
gap is the shell wiring**: 69 uncovered lines across `_undoGitOperation()` and
`_redoGitOperation()`, over a feature that mutates a repository. Same seam shape
as defect 3 — the logic tested, the UI join not.

Assertions, driven through `AppShell`:

* **⌘Z inside a text field stays text undo.** The guard at
  `app_shell.dart:522-531` checks `FocusManager.instance.primaryFocus` for an
  `EditableText` ancestor and returns. It is uncovered, and if it regresses a
  keystroke in the commit-message box reverts a git operation instead of a
  character.
* **`UndoStatus.dirty` prompts before overwriting**, and declining does not
  mutate — files changed since the operation ran must not be silently
  overwritten.
* **No active repo is a no-op**, not a crash (`repoPath == null` early return).
* **Redo mirrors undo** for each of the above.

**Required red:** remove the focus guard and observe the in-field test fail;
auto-confirm the dirty prompt and observe the overwrite test fail.

**Acceptance.** Tests red then green; suite +N. **Commit.**

---

### Phase 7 — T2.6: `connect()` / `connectLocal()`

**Files.** new `test/connect_paths_test.dart`.

68 uncovered lines on the path that establishes every session, and the path this
whole series keeps finding defects on: forge-auth races, generation pinning,
the connect-time watcher sweep, fsmonitor tuning.

Assertions:

* a superseded attempt (`_attempt` moved) neither marks, invalidates, nor logs
  against the new connection — the generation guard, which
  `fetchInBackground` documents and connect relies on;
* the connect-time watcher sweep runs, and a sweep failure does **not** fail the
  connect (`sweepStaleWatchers` is documented best-effort);
* `connectLocal` establishes a local backend without touching SSH state;
* a forge-auth failure leaves `forgeAuthPending` true rather than surfacing as a
  broken working tree.

**Required red:** per assertion, by breaking the guard it names.

**Acceptance.** Tests red then green; suite +N. **Commit.**

---

### Phase 8 — T3.8: assertion-strength heuristic

**Files.** new `test/assertion_strength_scan_test.dart`.

The general form of 0029. Flags a test whose **only** assertions about a
function are `contains(...)` on a string that same function generated — the
shape that let a dead sweep ship green for months.

Necessarily a **heuristic**, and the plan says so: it lists candidates for
review and fails only on a curated allowlist drift, in the same shape as 0029's
registry. It is not a proof.

**Required red:** a fixture test asserting only `contains()` on a generated
string is flagged.

> **Risk, from experience.** A source scan can produce false positives — one did
> today, in `refresh_no_flash_test`, where a 500-**byte** window reported a
> compliant site as an offender because an eight-line comment sat between the
> call and its argument. Choose windows in **lines**, and verify each negative.

**Acceptance.** Fixture red then green; the live list reviewed and either acted
on or recorded as accepted; suite +1. **Commit.**

---

### Phase 9 — Re-measure and record

**No code.** Retake the baseline table with the same commands, and record it
**including figures that did not move**. The MADR states the point is not that
81.4 % rises; a phase that adds two seam tests and moves coverage by 0.1 % has
still done its job, and the record must be able to say so without embarrassment.

Write the outcome into this plan and into the MADR's **Confirmation**.

## Verification

**Per phase:** the phase's own tests, plus

```sh
flutter analyze          # No issues found!
flutter test             # passing rises by exactly the tests added; failing 0
```

**Whole-plan acceptance.**

1. Every negative test observed red, verbatim, in the execution record.
2. `flutter analyze` clean; `flutter test` **0 failing** throughout.
3. **Phase 3's harness was seen to fail against at least one implementation**, or
   its first-run pass is recorded as a deviation with a decision.
4. Every site the Phase 1 scan flags is resolved *with a recorded reason*,
   including the ones deliberately left alone.
5. No test in this plan was written to move a percentage; no coverage target was
   adopted.
6. Any production change is a recorded deviation naming the contract row it
   satisfies.
7. The re-measurement is recorded including unmoved figures.

## Rollout and Rollback

Phases 1, 2, 4, 5, 6, 7, 8 are test-only; rollback is reverting the commits.
Phase 3 may carry production changes, each isolated to one contract row and one
deviation entry, individually revertable.

**The risk this plan actually carries is scope.** Phase 3 exists to find
differences between five implementations of a load-bearing abstraction, and it
is likely to find at least one that is a *design question* rather than a bug —
whether `ScopedCommandExecutor` should apply its env to `executeStream` as well
as `execute`, say. The temptation will be to answer it inside a testing plan.
It is a deviation: stop and prompt. A behaviour decided mid-sweep gets neither
its own record nor its own red test, which is precisely how the reclamation
sweep shipped dead.

A second, smaller risk: Phases 5–7 touch undo, upload and connect — three paths
whose failure modes are data loss, a lost edit, and a broken session. Tests
there must drive **fakes**, never a real repository or a real host; any phase
that finds itself wanting a live host has left its scope.

## Execution record

*(Empty until approved.)*

| Phase | Status | Commit | Red observed | Result |
|---|---|---|---|---|
| 1 | not started | — | — | — |
| 2 | not started | — | — | — |
| 3 | not started | — | — | — |
| 4 | not started | — | — | — |
| 5 | not started | — | — | — |
| 6 | not started | — | — | — |
| 7 | not started | — | — | — |
| 8 | not started | — | — | — |
| 9 | not started | — | — | — |
