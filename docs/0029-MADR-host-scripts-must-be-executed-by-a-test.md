---
status: "proposed"
date: 2026-09-04
decision-makers: [Maintainer]
consulted: []
informed: [Magic Git contributors]
verified: 2026-09-04
---

# A string assertion may pin a host script's composition, never its behaviour

## Context and Problem Statement

This app builds shell scripts in Dart and runs them on a host it cannot see.
Six such builders exist:

| builder | test files referencing it | test files **executing** it |
|---|---|---|
| `watcherSweepScript` | 2 | **1** |
| `boundedInotifyScript` | 1 | 0 |
| `boundedFswatchScript` | 1 | 0 |
| `catFileBatchScript` | 1 | 0 |
| `rootlessInstallScript` | 1 | 0 |
| `recursiveWatchScript` | **0** | **0** |

Five of six are covered only by assertions on the script's *text*, and one — the
recursive watcher, which carried the majority of the 19 orphaned `inotifywait`
processes found on the host — is referenced by no test at all. The single
executed case exists only because
[0027](0027-MADR-watcher-reclamation-cannot-reclaim.md) forced it.

**This is not a hypothetical gap. One of the six was proven dead.**
`watcherSweepScript` shipped, passed its tests, and **had never once been able
to reclaim a process**: it recorded a lease shell's pid and then refused to
signal anything whose `comm` was not `inotifywait`/`fswatch`, so its `case`
never fired. Its test asserted:

```dart
expect(s, contains('inotifywait'));
expect(s, contains('kill -TERM'));
```

Both strings were present. Both halves were individually correct. The
contradiction *between* them is the one thing substring matching cannot see. The
same guard was additionally `/proc`-only, so it was dead a second time on macOS
hosts — also invisible to a text assertion.

Three further instances landed in one working session:

* An experiment "confirming" a watcher survived its lease turned out to have
  written its log **inside the directory it was watching**, feeding its own
  events — 178,933,852 lines, 1.78 GB — so the timeout that drives the lease
  never fired. Read at face value it confirmed a defect that does not exist.
* An instrument probe reported `exited within 25s` having **never started**: its
  redirect failed because the log directory did not exist yet.
* `snapshot_fallback_test.dart` pinned `Isolate.run(() => parseRefsDetailed` and
  had to be rewritten when the mechanism moved — the *benign* version of the
  same coupling, where the check tracks spelling rather than behaviour.

The pattern is one thing: **a check that describes the shape of a mechanism
instead of exercising it.** `AGENTS.md` already says a check is not trusted
until it has been seen to fail; these all *were* seen to fail, on the wrong
thing.

## Decision Drivers

* **Host scripts are the least observable code in the system** — no analyzer, no
  type checker, no stack trace, and the failure mode is silence on a machine
  nobody is looking at.
* **The cost of the gap is measured, not feared**: 19 orphans, oldest 16.9 days,
  behind a green test suite.
* **A blanket "always execute" rule is not honest.** `inotifywait` does not
  exist on the macOS development machine and `rootlessInstallScript` installs
  binaries — some scripts genuinely cannot be run in a test.
* **Enforce in source, not in prose.** A convention in `AGENTS.md` did not stop
  any of the above.

## Considered Options

* **A — Require every host script to have an executing test.**
* **B — Separate what a string assertion may claim, and enforce coverage with a
  registry that fails on an unlisted builder.**
* **C — Require execution against a real host in CI.**
* **D — Document the hazard in `AGENTS.md` and rely on review.**

## Decision Outcome

Chosen option: **"B — separate what a string assertion may claim, and enforce
coverage with a registry"**, because it is the only option that is both
achievable and mechanical.

**The rule.** For a script this app sends to a host:

* a `contains(...)` assertion on script text may pin **composition** — that a
  path was interpolated, that a flag the caller passed came through, that a
  builder used the argument it was given;
* it may **never** be the only evidence for **behaviour** — that the script
  reclaims a process, terminates on a condition, produces a given output, or
  refuses an input. Behaviour is established by running the script and observing
  the effect;
* where a script cannot be executed on the development machine, that is
  recorded as a **named exemption with its reason**, not left to look like
  coverage.

A is rejected because it cannot be honoured for `inotifywait`-dependent scripts
on macOS, and a rule that cannot be honoured is one that gets waived silently.
C is rejected as it makes the suite depend on a reachable host — this project
already keeps `live-forge` tests skipped by default for that reason. D is
rejected because it is what was in place.

### Consequences

* Good, because the failure mode that shipped a dead sweep becomes visible: a
  new builder with no executing test and no exemption fails the suite.
* Good, because exemptions are enumerated rather than implicit, so "what is
  untested here" is answerable without an audit.
* Good, because it is cheap: `watcherSweepScript`'s executable tests took one
  helper (`isAlive`, `diedWithin`) and spawn a `sleep`.
* Bad, because executing tests are slower and can be flakier than string
  matching — they spawn processes and wait for signals. Mitigated by polling for
  the observable rather than sleeping a fixed interval, which is what
  `diedWithin` does.
* Bad, because an exemption is a place to hide. The registry makes each one
  visible and requires a written reason, which is the most that can be enforced
  mechanically.
* Neutral, because no existing behaviour changes; this adds tests and one scan.

### Confirmation

The scan is confirmed when it **fails** on a builder that has neither an
executing test nor a recorded exemption — demonstrated by adding one and
watching the suite go red, not by watching it pass.

Each newly-executed script is confirmed the way `watcherSweepScript` was: a real
process, a real effect, and a paired case proving the script *declines* to act
when it should — the direction that catches "kills everything" as well as "kills
nothing".

## More Information

* [`0027-MADR-watcher-reclamation-cannot-reclaim.md`](0027-MADR-watcher-reclamation-cannot-reclaim.md) — the sweep that could never reclaim anything, and why its tests missed it.
* [`0025-MADR-unaccounted-host-side-work.md`](0025-MADR-unaccounted-host-side-work.md) — **C1**/**C3**, the lease and registry these scripts implement; the 19 orphans.
* [`0028-PLAN-ceiling-refusal-and-teardown-residue.md`](0028-PLAN-ceiling-refusal-and-teardown-residue.md) — Phase 4, the self-feeding experiment and the probe that never started.
* `AGENTS.md` — "a check is not trusted until it has been seen to fail", which this record narrows to say *what* must be seen to fail.
