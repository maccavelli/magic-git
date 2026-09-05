---
status: "proposed"
date: 2026-09-05
decision-makers: [Maintainer]
consulted: []
informed: [Magic Git contributors]
verified: 2026-09-05
---

# Close the test gaps by shape, not by percentage

## Context and Problem Statement

Measured on 2026-09-05 with `flutter test --coverage`:

| | |
|---|---|
| line coverage | **81.4 %** (29,065 / 35,691) |
| files in report | 267 |
| **files with zero coverage (>40 lines)** | **0** |
| test files / lib files | 376 / 270 |
| suite | 3,508 passing, 2 skipped, 0 failing |

There is no untested corner of this codebase in the usual sense. Every file is
exercised by something, the ratio of test files to source files is above 1.3,
and the suite is green.

**And in a single working session it produced five defects, four of them in code
that had coverage.** That is the problem this record is about: the gaps are not
*sized*, they are *shaped*. Chasing 81.4 % toward 90 % would have prevented none
of the five.

### The five, and what kind of test was missing

| # | defect | had coverage? | what the tests asserted | what nobody asserted |
|---|---|---|---|---|
| 1 | the connect sweep **could never reclaim a process** — recorded a shell's pid, signalled only `inotifywait`/`fswatch` | yes | the script's *text* contained `inotifywait` and `kill -TERM` | that running it kills anything |
| 2 | the watcher **never armed** — the client stamped the lease *after* launching the script that checks for it | yes | two instances own distinct lease files | the *order* of the two host operations |
| 3 | the panel **blanked on every refresh** — a derived provider reloads, and `when` shows loading on reload | yes | providers resolve; widgets render | what the widget shows *while* a refetch is in flight |
| 4 | watcher diagnostics existed for **one of two backends** | yes | the remote service records transitions | that *both* implementations do |
| 5 | `start()` had no re-entrancy guard; two arms, one teardown | yes | arming, restarting, degrading each work | two of them overlapping |

Four distinct shapes, and only one of them ("no test at all") is what a coverage
number measures:

* **A — the seam.** Two components are each correct and their join is not tested
  (1, 2, 4, 5).
* **B — composition asserted, behaviour assumed.** A `contains(...)` on
  generated text stands in for running it (1). Addressed by
  [0029](0029-MADR-host-scripts-must-be-executed-by-a-test.md) for host scripts;
  the general form is unaddressed.
* **C — parity.** An abstraction has N implementations and the tests cover a
  subset (4, and see the measurement below).
* **D — the in-flight state.** Tests assert the settled result and never the
  intermediate one (3).

Coverage cannot see any of these. A line executed once by a happy-path test is
100 % covered and says nothing about ordering, parity, concurrency, or what the
UI displays mid-flight.

## What the measurement *does* show

Two findings worth acting on, both risk-weighted rather than percentage-ranked.

### Parity is measurably lopsided

`CommandExecutor` — the load-bearing abstraction, per `AGENTS.md` — has five
implementations. Test files naming each, and their line coverage:

| implementation | test files | coverage | used by |
|---|---|---|---|
| `SSHCommandExecutor` | 126 | 82.9 % | remote repos |
| `LocalCommandExecutor` | 34 | 85.0 % | local repos |
| `ScopedCommandExecutor` | **3** | **40.9 %** | scoped/dotfiles repos |
| `ActivityCommandExecutor` | **1** | 66.7 % | operation lifecycle |
| `ProxyCommandExecutor` | **1** | 60.0 % | **every pop-out window** |

Defect 4 was exactly this shape, in the watch services. The executor seam has
the same shape and a wider spread.

### The largest uncovered regions are not obscure

Uncovered lines mapped to their enclosing function:

| function | uncovered | what it does |
|---|---|---|
| `AppShell.build()` | 99 | the shell |
| `ForgeDetector.detect()` | 111 | forge detection at connect |
| `_undoGitOperation()` + `_redoGitOperation()` | **69** | **⌘Z / ⇧⌘Z on git operations** |
| `connect()` + `connectLocal()` | 68 | session establishment |
| `ProxyCommandExecutor.uploadBytes()` | **18 of its 26** | **a pop-out editor writing a file back to the host** |
| `_openPalette()` + `_openPaletteEntity()` | 48 | command palette |

Two of these are risk-weighted far above their size. **Undo/redo mutates a
repository**, and **`uploadBytes` writes a user's file to a host** — from the
pop-out path, in the executor with one test file, at 60 % coverage.

## Decision Drivers

* **The evidence is unusually direct.** Five defects, in one session, with their
  shapes recorded. This does not need to be argued from principle.
* **A percentage target would mis-spend the effort.** Reaching 90 % is roughly
  3,000 lines of new assertions and would not have caught any of the five.
* **Enforce in source, not prose** — the repo's own rule, and the one that
  worked: 0029's registry now fails on an unclassified host script, where an
  `AGENTS.md` sentence had not.
* **A check is not trusted until seen to fail.** Every proposal below must be
  landable red-then-green; a proposal that cannot be is not accepted.
* **Risk over size.** A 69-line gap over `git reset` beats a 111-line gap over
  forge detection.

## Considered Options

* **A — Raise line coverage toward a target (90 %).**
* **B — Shape-driven: tests and scans aimed at the four failure shapes, ordered
  by risk.**
* **C — Mutation testing.**
* **D — Nothing; the suite is green and 81.4 % is healthy.**

## Decision Outcome

Chosen option: **"B — shape-driven, ordered by risk"**, because the failure
shapes are documented rather than hypothesised, and because the coverage number
is already high enough that its marginal line is worth much less than a seam
test.

**A** is rejected: it optimises the metric that was already satisfied for four
of the five defects. **C** is attractive in principle — mutation testing detects
exactly shape B, the assertion that cannot fail — but Dart's tooling is immature,
a full mutation run over 35k lines is far beyond this suite's runtime budget, and
the manual equivalent (sabotage-and-observe) is already the practice here and
caught every regression today. **D** is rejected by the five defects.

### The proposals, in priority order

Each is stated so it can be landed red-then-green.

#### T1 — Seam tests (shape A; four of five defects)

1. **Executor parity harness.** One shared test body run against every
   `CommandExecutor` implementation, asserting the contract they all claim:
   argv is never a shell string, output byte budgets bound, a non-zero exit
   surfaces as failure, cancellation does not leak. Today `ProxyCommandExecutor`
   and `ActivityCommandExecutor` have one test file each.
   *Red:* the harness run against `ProxyCommandExecutor` before it is made to
   satisfy the contract.
2. **Backend parity guard, generalised.** `watch_diagnostics_both_backends_test`
   exists for the watch services after defect 4. Generalise it: a scan that, for
   each abstraction with multiple implementations, fails when one implementation
   is named by tests and a sibling is not.
   *Red:* remove a sibling's test reference.
3. **Ordering invariants at host seams.** Defect 2 was an ordering property
   between the service and the script it launches. Test the order of host
   operations for each arm-like path — lease before arm, pid recorded before
   the process can be signalled, scope env applied before the command that needs it.
   *Red:* swap the two operations.

#### T2 — Risk-weighted uncovered paths (shape: genuinely untested, and dangerous)

4. **`ProxyCommandExecutor.uploadBytes()`** — a pop-out editor writing a file to
   a host, 18 of 26 lines uncovered. Assert the relay carries bytes intact
   (`Uint8List`, never `String` — the codec truncates at NUL, which this repo
   already learned once), that a missing `routingRepo` is refused, and that a
   failed upload surfaces rather than silently dropping the edit.
5. **Undo / redo of git operations** — 69 uncovered lines over a
   repository-mutating feature. Assert the journal round-trips, that ⌘Z in a
   text field stays text undo (the guard at `app_shell.dart:522` is uncovered),
   and that undoing an operation whose repo has since changed refuses rather
   than applying blind.
6. **`connect()` / `connectLocal()`** — 68 uncovered lines on the path that
   establishes every session, and the one whose failure modes this series has
   repeatedly found (forge-auth races, generation pinning, sweep-at-connect).

#### T3 — Cheap enforcement (prevents recurrence, ~1 test each)

7. **In-flight render guard, generalised.** `refresh_no_flash_test`'s scan
   covers `.when()` on snapshot-derived providers. Widen it to every
   `AsyncValue` render whose provider is *derived from another provider*, which
   is the condition that turns a refresh into a reload.
8. **Assertion-strength scan.** The general form of 0029: flag a test whose
   only assertions about a function's behaviour are `contains(...)` on a string
   that function *generated*. Not automatable in full; a heuristic that lists
   candidates for review is enough, and would have flagged defect 1.

### Consequences

* Good, because each proposal targets a shape with a recorded instance, so the
  argument for it is evidence rather than taste.
* Good, because T3 is enforcement — it prevents the class rather than fixing one
  case.
* Good, because T2 raises coverage where a defect would be *expensive* (lost
  edits, wrong repository state) rather than where it is merely absent.
* Bad, because a parity harness constrains implementations to a contract they
  currently satisfy only loosely; making `ProxyCommandExecutor` satisfy it may
  surface real differences that need deciding, not just testing. That is a
  feature of the proposal and a cost of it.
* Bad, because T1.2 and T3.8 are scans over source, and a scan can produce false
  positives — one already did, in `refresh_no_flash_test`, where a byte-window
  reported a compliant site as an offender. Scans need their windows chosen in
  the right unit and their negatives verified.
* Neutral on the coverage number: T2 moves it a little, T1 and T3 barely at all.
  **This record does not propose a coverage target and recommends against
  adopting one.**

### Confirmation

This record is confirmed when each proposal has been landed red-then-green, with
its verbatim red in the paired plan — and specifically when T1.1's harness is
observed *failing* against `ProxyCommandExecutor` before that implementation is
brought up to the contract. A parity harness that passes on first run against
every implementation has not established parity; it has established that the
harness asserts nothing the implementations do not already share.

The measurement above should be retaken after T2, and **recorded including any
figure that did not move** — the point is not that 81.4 % rises.

## More Information

* [`0029-MADR-host-scripts-must-be-executed-by-a-test.md`](0029-MADR-host-scripts-must-be-executed-by-a-test.md) — shape B for host scripts; the registry idiom T1.2 and T3.8 generalise.
* [`0027-MADR-watcher-reclamation-cannot-reclaim.md`](0027-MADR-watcher-reclamation-cannot-reclaim.md) — defect 1, and its deviation (b) is defect 2.
* [`0026-MADR-degraded-watch-poll-diagnosis.md`](0026-MADR-degraded-watch-poll-diagnosis.md) — defect 5, and its deviation (c) is defect 4.
* [`0025-PLAN-unaccounted-host-side-work.md`](0025-PLAN-unaccounted-host-side-work.md) — deviation (e) is defect 3.
* `AGENTS.md` — "a check is not trusted until it has been seen to fail", and the executor seam this record measures parity across.
