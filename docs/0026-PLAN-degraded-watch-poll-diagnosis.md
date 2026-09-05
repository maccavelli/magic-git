---
status: "in-progress"
date: 2026-09-04
associated-madr: "0026-MADR-degraded-watch-poll-diagnosis.md"
---

# Implement the watcher mode-transition instrument and capture the degraded-poll cause

Associated MADR: [0026-MADR-degraded-watch-poll-diagnosis.md](0026-MADR-degraded-watch-poll-diagnosis.md)

## Goal

Determine, from evidence rather than plausibility, why `watchLifecycle`
degrades to its 5-second poll while live `inotifywait` processes exist on the
host — the condition MADR 0025 C4 measured at **53 % of all observed host
processes**, and 48 git processes per minute while it lasts.

The deliverable of this plan is **a diagnosis, not a fix.** It ends with one of
H1/H2/H3 confirmed or all three refuted, recorded here, and a successor plan
proposed for the fix that diagnosis selects.

## Scope

**In scope**

* A bounded, in-memory mode-transition log in `watchLifecycle`, with the live
  watcher count and arm outcome at each transition.
* Surfacing it where a maintainer can read it during a real session.
* Tests that prove the instrument records the *unhealthy* transitions, driven
  by deliberately broken inputs.
* One capture from a real session against the live host, and its analysis.

**Explicitly out of scope** — each is a candidate fix for a *different*
hypothesis, and adopting one before the capture is the guess this plan exists
to avoid:

* changing `maxConcurrentWatchers` (`remote_watch_service.dart:142`);
* adding a re-entrancy guard to `start()`;
* changing `recoveryInterval` or `pollInterval`;
* making the ceiling's `WatchUnavailable` distinguishable from the host's;
* anything touching teardown or `releaseSlot()`.

If the capture confirms a cause, the fix is a **successor plan**, numbered
separately, and is not smuggled into this one.

## Preconditions

```sh
flutter --version | head -1          # must equal FLUTTER_VERSION in build_macos.sh (3.47.2)
flutter pub get --enforce-lockfile   # "Got dependencies!"
git status --short                   # empty
flutter analyze                      # No issues found!
flutter test                         # 3468 passing, 2 skipped, 0 failing
```

Any deviation from **3468 / 2 / 0**: stop and prompt — the baseline moved.

## Implementation Steps

### Phase 1 — The transition record

**Files.** new `lib/core/git/watch_diagnostics.dart`; `test/watch_diagnostics_test.dart`.

A value type and a bounded ring buffer. No engine changes yet, so this phase is
pure and testable in isolation.

```dart
enum WatchTransition { armed, armFailed, restartScheduled, degradedToPolling,
                       recoveryAttempted, recovered, rearmed, stopped }

class WatchTransitionRecord {
  final DateTime at;
  final WatchTransition kind;
  final String repoPath;
  final String cause;        // 'ceiling 2/2' | 'onDone' | 'no tool' | 'budget' | …
  final int liveWatchers;    // RemoteWatchService._liveWatchers at that instant
  final int restarts;        // the engine's spent budget
}
```

Bounded at 200 records per repo, oldest dropped — the log must not become the
memory leak it is investigating.

**1a. Negative test.** `expect(log.records, hasLength(200))` after 250 adds,
and the oldest dropped. **Required red:** `Expected: <200> / Actual: <250>`
before the bound exists.

**Acceptance.** Test red then green; suite +N; analyzer clean. **Commit.**

### Phase 2 — Wire it into the engine

**Files.** `lib/core/git/watch_lifecycle.dart`, `lib/core/git/remote_watch_service.dart`;
`test/watch_lifecycle_test.dart`.

Record a transition at each existing mode change — `startPolling()` `:145`,
`scheduleRestart` `:174`, the `WatchArmed`/`WatchUnavailable`/`WatchAborted`
arms `:241-256`, and the recovery timer `:155`. **No behaviour changes**: every
call site already exists; this adds a record and nothing else.

`RemoteWatchService` supplies `cause` and `liveWatchers` at the ceiling refusal
(`:270-275`), the budget refusal (`:300-307`), and the bounded-no-paths exit
(`:326-330`), so a `WatchUnavailable` says *which* of them it was — the
distinction the engine currently cannot make.

**2a. Negative test — the instrument must be seen to fail.** Not a healthy
transition; the unhealthy ones it exists for:

```dart
test('a ceiling refusal is recorded as degradedToPolling with its cause', () async {
  // arm maxConcurrentWatchers watchers, then one more
  expect(log.records.last.kind, WatchTransition.degradedToPolling);
  expect(log.records.last.cause, contains('ceiling'));
  expect(log.records.last.liveWatchers, 2);
});
```

**Required red:** no record at all before the wiring — `Actual: <null>`.

**2b. The H1 race, driven directly.** The discriminating test:

```dart
test('two overlapping start() calls both reserve a watcher slot', () async {
  // hold arm() open; enter start() twice; release
  expect(RemoteWatchService.liveWatchers, 1, reason: 'one repo, one slot');
});
```

**Required red, if H1 is real:** `Expected: <1> / Actual: <2>`.

> This test is the plan's single most important artifact. A red here confirms
> H1 **without needing the live capture at all**, and the plan may stop early
> and propose the fix. A green refutes H1 and the capture proceeds to
> discriminate H2 from H3. Either outcome is a result; neither is a failure of
> the plan.

**Acceptance.** Both tests red then green (2b green meaning *refuted*, recorded
as such); full suite +2; **no behavioural test changes anywhere else** — if any
existing test changes, the wiring was not behaviour-neutral and that is a
deviation. **Commit.**

### Phase 3 — Make it readable during a session

**Files.** `lib/features/...` (the existing output/diagnostics surface);
`test/...` matching.

Surface the log where `onDiagnostic` already goes — the watcher already routes
diagnostics to the output log (0024 H3), so this is a consumer, not a new
channel. A maintainer must be able to answer "why is this repo polling" while
it is polling.

**Acceptance.** Widget test asserting the records render; suite +1. **Commit.**

### Phase 4 — Capture and analyse

**No code.** Method as MADR 0025's re-measurement, which is validated:

1. Back up `~/.gitconfig` on the host (`cp -p`), record its sha256.
2. Arm `trace2.eventTarget`; **run the control** — *n* known invocations must
   log ≥ *n*. This instrument has failed twice; it is not trusted until seen to
   work.
3. Run the app normally until a degradation occurs (regime A: a 5-second,
   4-process metronome in the trace).
4. Capture the transition log **and** the `/proc` census together, at the same
   instant — the pairing is the point: which processes exist versus what the
   engine believed.
5. Restore `~/.gitconfig`, verify byte-identical, remove the trace.

**Analysis, decided in advance** so the reading is not fitted to the result:

| observation | verdict |
|---|---|
| two `armed` records for one repo with overlapping timestamps | **H1** |
| `degradedToPolling` with `cause` containing `ceiling` and `liveWatchers == 2` | **H2** |
| ≥ 3 `restartScheduled` with `cause == onDone`, then `degradedToPolling` | **H3** |
| refusals with `liveWatchers == 2` while `/proc` shows **0** watchers | **H1**, slot leak |
| none of the above | all three refuted — successor MADR, not a fix |

**Acceptance.** The capture recorded verbatim here, the verdict stated, and
`~/.gitconfig` byte-identical with nothing left on the host.

### Phase 5 — Record the outcome

Write the verdict into this plan and into MADR 0026's **Confirmation**, and
propose the successor plan for the fix. If all three are refuted, MADR 0026
gets a successor record rather than an amendment — the mechanism would be one
nobody has enumerated.

**No fix is implemented under this plan number.**

## Verification

**Per phase:** the phase's own tests, plus

```sh
flutter analyze          # No issues found!
flutter test             # passing rises by exactly the tests added; failing 0
```

**Whole-plan acceptance.**

1. Every negative test was observed red, with its verbatim failure recorded
   here — including 2b, whose red *is* the diagnosis.
2. `flutter analyze` clean, `flutter test` 0 failing throughout.
3. Phase 2 changed no existing test's expectations (proof the wiring is
   behaviour-neutral).
4. The capture is recorded verbatim, with the verdict from the pre-committed
   table above.
5. `~/.gitconfig` on the host restored byte-identical; no trace files, samplers
   or stray processes left behind.
6. No item from the out-of-scope list was touched.

## Rollout and Rollback

The instrument is additive and behaviour-neutral: it records transitions the
engine already performs and issues no host commands. Rollback is reverting the
phase commits; nothing persists on the host and no user-visible behaviour
changes, so there is no migration and no state to unwind.

The risk this plan carries is not to the running app — it is that a capture
never arrives because the condition does not recur. If no degradation is
observed within a week of normal use, that is itself reportable: it would mean
regime A is rarer than one occurrence per 21-minute window suggested, and the
finding's weight should be revised down accordingly rather than left standing.

## Execution record

*(Empty until approved. Filled in during execution: what each phase did, the
verbatim red-test output, the capture, and a dated entry for every deviation.)*

| Phase | Status | Commit | Red-test observed | Result |
|---|---|---|---|---|
| 1 | not started | — | — | — |
| 2 | not started | — | — | — |
| 3 | not started | — | — | — |
| 4 | not started | — | — | — |
| 5 | not started | — | — | — |

## Deviations

### Deviation (a) — 2026-09-04 — Phase 1 uncovered a load-sensitive check in 0024's P1 test

**Found** running Phase 1's full-suite gate. `test/ssh_live_transport_test.dart`
— *"the connect probe no longer waits on a login shell (0024 P1)"* — failed with
`Expected: a value less than 0:00:00.186114 / Actual: 0:00:00.347185`.

**Confirmed pre-existing, not caused by this work.** `git status` shows the test
file and the whole of `lib/core/ssh/` untouched; Phase 1's entire change set is
two new files (`watch_diagnostics.dart` and its test) that nothing imports yet,
so no code path under test executes any of it. Re-run in isolation the same test
passes (prelude 215 ms vs probe 96 ms), and it passed twice earlier the same day
at 105 ms and 95 ms. It is marginal under load, not newly broken.

**The defect is in the instrument.** At `:738-760` it takes **one** sample of
the removed-prelude path, then **one** of the current probe, sequentially, and
compares them directly. Any load arriving between the two measurements is
attributed to the probe. The check therefore measures load drift as much as the
thing it claims to measure — and a check that fails for reasons unrelated to its
claim is one that will eventually be ignored.

**Decision (maintainer): fix the instrument, and file the deviation against
0024 as well** — 0024 owns finding P1 and wrote this test, so the record belongs
where the instrument lives, not only where it happened to surface.

**Fix.** Interleave N paired samples and compare medians. The claim is
unchanged — the current probe must still beat the prelude that was deleted, and
the test still fails if removing the prelude did not help — but a transient load
spike now affects both arms equally instead of only the second. Deliberately
**not** done: widening the tolerance, marking it skipped, or dropping the
assertion, all of which would leave the real timing claim unguarded.

**Files added to Phase 1's scope:** `test/ssh_live_transport_test.dart`.
