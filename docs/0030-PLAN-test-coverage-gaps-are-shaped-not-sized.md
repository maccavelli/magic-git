---
status: "in-progress"
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
| 1 | executed | — | scan named `project_sections.dart:458` | 2 sites fixed, 1 recorded correct-as-is, blind spot found |
| 2 | executed | — | fixture rule flagged `Seam.Beta` | live scan green; 2 seams, 3 private impls exempt |
| 3 | executed | — | 3 sabotages, incl. a real injection | parity sound; 16 rows, wrappers + real processes |
| 4 | executed | — | `'recorded'`→`'MISSING'`; `Set:['pipelinesProvider']` | 2 invariants; the third was absorbed by Phase 3 |
| 5 | not started | — | — | — |
| 6 | not started | — | — | — |
| 7 | not started | — | — | — |
| 8 | not started | — | — | — |
| 9 | not started | — | — | — |

## Execution notes

### Phase 1 as executed — 2026-09-05

**Required red met.** Widening the derived-set discovery from "references
`repoSnapshotProvider`" to "awaits any `\w+Provider(...).future`" made the scan
name a site beyond the two already fixed:

```
lib/features/forge/project_sections.dart:458  detail.when() on issueDetailProvider
```

**Three sites resolved, each with a recorded reason** — as 1b required,
including the one deliberately left alone:

| site | decision |
|---|---|
| `project_sections.dart:458` — `detail.when()` on `issueDetailProvider` | **fixed.** Awaits `forgeProvider(repoPath).future`, so a repo-scoped refresh reloads it and ⌘R while viewing an issue blanked the pane. Selecting a *different* issue changes the family key — a new instance with no previous value — which still shows the spinner, correctly. |
| `forge_widgets.dart:834` — `comments.when()` | **fixed.** Fed by `issueCommentsProvider`, same `forgeProvider.future` chain. **The scan did not find this one**; it was found by reading. |
| `dashboard_sheet.dart:232` — `value.when()` | **left alone, with a comment.** `sessionAuthStatusProvider` watches `connectionProvider`, so it recomputes when the *connection* changes. Holding the previous value would present one host's CLI auth state as the new host's — worse than a spinner. |

### Deviation (a) — 2026-09-05 — the scan has a boundary blind spot

**Found** during Phase 1b. The scan matches `final x = ref.watch(<derived>(…))`
followed by `x.when(` **in the same file**. An `AsyncValue` handed across a
widget boundary — a constructor field or a method parameter — escapes it
entirely, and that is how `forge_widgets.dart:834` hid: its provenance is not
visible where it is rendered.

**Nine `AsyncValue`s cross a boundary in `lib/features`.** A probe over them
found three rendered with `.when()`: two already carried the flag, and the third
is `dashboard_sheet.dart:232`, which should *not* carry it.

**Decision: record it, do not widen Phase 1 to cover it.** A stricter regex
would over-flag, because at least one boundary-crossing site is correct as it
stands — so closing this needs an **allowlist of reviewed sites with reasons**,
which is exactly 0030 Phase 8's shape (0029's registry idiom) and not this
phase's. Carried to Phase 8; the blind spot is written into the test itself so a
reader does not mistake a green scan for full coverage.

### Phase 2 as executed — 2026-09-05

The scan finds both multi-implementation seams and, as the plan predicted, is
**green on the live tree** — every public implementation is named by some test:

```
SEAMS: {CommandStreamHandle: 3, CommandExecutor: 5}
PRIVATE (exempt by construction): [_SshSessionStreamHandle, _ActivityStreamHandle,
                                   _LocalActivityStreamHandle]
```

**The value is therefore the fixture test, exactly as the plan said.** The rule
is extracted with its naming function injected, so the negative case drives it
over a fixture: it flags `Seam.Beta` (a sibling no test names), lists
`Seam._Gamma` as private-exempt rather than dropping it, and flags nothing when
every sibling is named.

**A first attempt was wrong and is recorded rather than quietly replaced.** The
negative case originally asserted `testFilesNaming('class Beta implements') == 0`
against the real `test/` directory — and got **1**, because that string appears
in the fixture literal inside this very test file. A scan that reads `test/`
cannot be negative-tested by writing the offending pattern into `test/`.
Injecting the naming function is what makes the negative case honest.

**Blind spot recorded in the test:** implementations are grouped by the name as
written, so a class implementing a *typedef alias* forms its own group.
`_ProcessStreamHandle implements SSHStreamHandle` does not join the
`CommandStreamHandle` seam. It is private and exempt either way, so nothing is
missed today; a public class written against an alias would slip the rule.

### Phase 3 as executed — 2026-09-05

**Outcome: parity is sound.** The harness found no live defect, and per 3a that
could not close the phase, so the rows were pushed harder rather than the result
accepted — first into a real assertion where one was hollow, then into
`LocalCommandExecutor` driven with **real child processes**.

**Sixteen rows.** R1–R6 over the wrapper implementations against a recording
inner; R7–R10 over `LocalCommandExecutor` against the OS:

| row | claim | result |
|---|---|---|
| R1–R3 | argv, extraEnv and `uploadBytes` reach the inner unmodified | pass, all wrappers |
| R4 | the environment contract | `Scoped`/`Activity` delegate; **`Proxy` deliberately does not**, and the harness pins that *intent* |
| R5 | `Scoped` scopes streams as well as commands | pass |
| R6 | `Proxy.uploadBytes` refuses without `routingRepo` | pass |
| R7 | **argv is never a shell string** | pass |
| R8 | a non-zero exit is reported | pass |
| R9 | **cancelling a stream kills the child process** | pass |
| R10 | `uploadBytes` writes exact bytes, NUL included | pass |

**A hollow assertion of my own was found and replaced.** R5 was originally
`expect(streamed || true, isTrue)` — an assertion that cannot fail, written into
the very harness whose purpose is to catch assertions that cannot fail. It now
asserts the scope reaches `executeStream`, and is one of the sabotaged rows
below.

**Three sabotages, all observed:**

| what was broken | observed |
|---|---|
| `Scoped.executeStream` drops the scope merge | `Expected: {'GIT_DIR': '/g'} / Actual: <null>` |
| `cancel()` closes the stream without signalling the process | `Expected: true / Actual: <false>` — the process survived |
| argv joined into `sh -c` | `Expected: 'hello; touch …/pwned' / Actual: 'hello'` — **the injection executed** |

The third is the one worth keeping in mind: R7 is not a style rule. With argv
joined into a shell string the canary command ran, and the row caught it.

**Design questions checked rather than assumed.** The plan predicted Phase 3
would surface a difference needing a decision. Two were examined and both are
already settled: `ScopedCommandExecutor` applies its scope to *both* `execute`
and `executeStream`, and `ProxyCommandExecutor`'s environment no-ops are
deliberate and documented (a pop-out relays to the main isolate, which owns
binary resolution and the `argv[0]` rewrite). No production change was needed.

**Stated limit.** `SSHCommandExecutor` is not driven by this harness: it owns a
transport that needs a live socket, and it is the most-tested implementation
(126 test files) with its own live-sshd suite. The exclusion is written into the
test file, so "parity" here means *every implementation reachable in-process*,
not literally all five.

### Phase 4 as executed — 2026-09-05

**Invariant A was absorbed by Phase 3 and is not duplicated.** The plan listed
"scope env before the command that needs it" as its own test; contract rows R2
and R5 already assert the merged env reaches both `execute` and `executeStream`,
and R5 was sabotage-proven. Writing it twice would be coverage theatre. Recorded
here rather than silently dropped.

**Invariant B — a watcher records its pid before it can be signalled.** The
real script runs with `inotifywait` shimmed onto `PATH`, and the shim reports
whether the pid file was populated *at the moment it started*. A watcher that
runs before it is recorded is one the sweep can never name, which is what made
the host's orphans permanent (0027 amendment 0027.1).

Seen to fail with the pid prelude removed: `Expected: 'recorded' / Actual:
'MISSING'`.

**Invariant C — forge reads wait for the connect-time login.** `_forgeAuthReady`
holds a forge data provider until the session's background CLI logins settle, so
a panel visible at connect loads against an authenticated CLI rather than
flashing a transient auth error. The scan asserts every provider that calls a
gh/glab service either awaits the gate or is on a reviewed list.

Seen to fail with the gate removed from one provider:
`Actual: Set:['pipelinesProvider']`.

**A finding, recorded and not silently allowlisted.** Fourteen forge providers
await the gate; **six do not**:

```
changeRequestCommentsProvider, issueCommentsProvider, issueDetailProvider,
projectLabelsProvider, projectMilestonesProvider, projectReleasesProvider
```

They are listed as `reviewedWithoutGate` with the reason stated in the test:
all six are **drill-in** providers, watched only once the user selects an issue,
milestone or release, which cannot happen before connect completes. That
reasoning is sound today and is written down so it can be checked rather than
assumed.

**It is worth a maintainer's eye**, because the exemption rests on a UI
assumption rather than a structural guarantee: if the Forge tab ever restores a
selection at connect, one of these fires immediately and shows a transient auth
error as its error state. Adding the gate to all six would cost nothing for
sessions without managed tokens (the future is already complete) — but it is a
behaviour change, and this is a testing plan, so it is reported rather than
taken.
