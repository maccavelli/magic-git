---
status: "complete (amended)"
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
* ~~adding a re-entrancy guard to `start()`~~ — **brought into scope 2026-09-04
  by deviation (b)**, after Phase 2b proved H1 deterministically. The exclusion
  existed to prevent choosing a fix before a cause was known; the cause is now
  known;
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
| 1 | executed | `c4b361f` | `Expected: an object with length of <200>` against 250 retained | bounded transition log; 0024's P1 flake fixed (deviation (a)) |
| 2 | executed | `4d83f5d` | `Expected: <2> / Actual: <1>` — two sources armed, one torn down | **H1 CONFIRMED**; fix landed under deviation (b) |
| 3 | executed | `da53623` | `Expected: non-empty / Actual: []` with the summary suppressed | degradations explained on the existing diagnostic channel |
| 4 | executed | — | n/a (measurement) | **degraded-poll regime did not recur**; new finding: orphans survive the lease (0025 C5) |
| 5 | executed | *(this entry)* | — | verdict recorded; H2/H3 left open, not closed |

### Verdict — H1 confirmed, H2 and H3 untested

**H1 is confirmed**, deterministically and without the live capture the plan
budgeted for. `test/watch_transition_wiring_test.dart` drives two overlapping
`start()` calls and asserts every armed source is torn down:

```
overlapping start() calls: every armed source is torn down [E]
  Expected: <2>
    Actual: <1>
  both armed sources must be torn down; H1 is real if only one is
```

Two sources armed; one teardown ran. The other stayed live with nothing holding
it — the orphaned watcher, and the leaked slot that then refuses every later arm
and drops the repo to the 5-second poll.

**The fix** serialises arming: `start()` chains onto the previous attempt
instead of racing it, so a re-arm requested during an in-flight arm runs *after*
the teardown it depends on. At most one follow-up is queued, because three
timers firing during one slow arm should produce one re-arm, not three. The
ceiling was **not** raised and no interval was touched — the two changes that
would have hidden the symptom rather than removed it.

**Both halves of the fix were seen to fail.** Serialisation removed:
`Expected: <1> / Actual: <2>`. Collapsing removed: `Expected: <2> / Actual: <4>`
— three re-arms producing four arms. Each sabotage was applied to a backed-up
copy and the source restored byte-identical afterwards, verified with `cmp`.

> **A correction worth recording:** the first sabotage attempt *passed*, and it
> was wrong rather than the check being weak — it disabled the collapsing guard,
> not the serialisation, which lives in the `startChain.then(...)` chain. The
> passing run was the signal to re-read the mechanism. It also exposed that the
> collapsing guard had no test of its own, which is why one was added.

**H2 and H3 are neither confirmed nor refuted.** H1 accounts for every observed
symptom and is now proven, so neither was pursued. They are **open**, not
eliminated:

* **H2** — a ceiling refusal is still indistinguishable to the engine from
  "this host has no watcher tool", so both get the same 3-minute recovery. The
  instrument now records *which* it was (`cause: 'ceiling 2/2'` vs
  `'no watcher tool'`), so a future capture can settle it. And
  `_liveWatchers` is still `static` — process-global — while documented as
  per-connection.
* **H3** — teardown-does-not-kill (0022 M5) is untested here and unaffected by
  this fix.

### Phase 4 as executed — post-fix capture, 2026-09-04

Taken against a build containing `4d83f5d` (app binary built 20:34; fix
committed 20:24:52 — verified before capturing, not assumed). Control passed
(6 start events for 5 known invocations). `~/.gitconfig` restored
byte-identical (sha256 `3134c8a2…`), trace and backups removed.

**The degraded-poll regime did not recur.** Over a 300 s window the trace holds
92 start events spanning only 166 s, and their shape is user activity — `diff`,
`ls-files`, `check-ignore`, a fetch — not poll ticks:

| | pre-fix (2026-09-04, regime A) | post-fix |
|---|---|---|
| cadence | **4 events every 5 s, 19 consecutive ticks** | none |
| longest silence | 0 s during the regime | **142 s** mid-window, and ~134 s more after the last event |
| watcher trees | 2 trees + duplicates on **one** repo | **2, exactly the ceiling** |
| inter-event gaps | uniform 5 s | 1, 2, 4, 10, then 142 |

There is no metronome. Idle costs nothing, which is what regime B established as
the healthy state and what the fix was meant to restore.

**But the capture found something else**, which is why Phase 4 was worth running
even after H1 was settled by test.

### New finding — orphaned watchers survive the lease and are invisible to the sweep

Two lease shells were alive with `ppid 1`, aged **1145 s and 1127 s** (~19
minutes), with **zero child processes** — not watching anything, just resident.
They predate the rebuild, so they are the previous app instance's orphans. Both
of 0025's reclamation mechanisms failed on them, and the capture shows exactly
why:

```
mg-watch.pid = '331312'      <- the NEWEST watcher only; the orphans are named nowhere
mg-watch.hb   mtime age 0s   <- FRESH, written by the CURRENT app every 60s
find mg-watch.hb -mmin -5    -> FRESH: an orphan re-checking its lease would NOT exit
```

* **The lease is keyed per repository, not per watcher.** An orphan's loop tests
  `mg-watch.hb`, and its *successor* refreshes that same file every 60 s. The
  successor therefore holds its predecessor's lease open indefinitely. The
  self-termination built in 0025 Phase 4 cannot fire while any watcher for that
  repo is healthy — precisely when orphans accumulate.
* **The PID file is overwritten by each arm.** `mg-watch.pid` names only the
  newest watcher, so `sweepStaleWatchers` (0025 Phase 3) has no record of the
  orphan to reclaim at connect. It is not that the sweep ran and failed; it had
  nothing to find.

This is **not** H1 recurring — the fix holds, and these orphans predate it. It is
a distinct defect in the reclamation machinery, recorded as **MADR 0025 C5**.
It is also the mechanism that lets orphans reach the ages 0022 M5 measured
(oldest 16.9 days): nothing can reclaim a watcher once its successor has
overwritten the pid file and taken over the heartbeat.

**Not fixed here.** 0026 is a diagnosis of the poll path; this is a different
defect in a different mechanism, and choosing its remedy — per-watcher lease
files, an append-only pid registry, or a generation stamp — is a decision, not a
detail. Two orphaned shells remain on the host, reported rather than killed.

The post-fix capture the plan asks for **has not been taken**: it requires the
app rebuilt with the serialisation fix, and the running build predates it. What
was taken is a **pre-fix reading**, so a comparison exists later:

```
real inotifywait binaries : 1     (0 orphaned by ppid)
lease shells              : 4     for ONE repo, against a ceiling of 2
distinct repos watched    : 1
```

Four lease shells for a single repo, where two watchers are the maximum, is
consistent with H1's duplication — but a census cannot separate that from
ordinary re-arm churn (the shells self-terminate on a stale heartbeat), and it
is **not** offered as confirmation. The deterministic test is the evidence; this
is context.

**The plan is complete.** Its question — why does the watcher degrade while its
host processes live — is answered (H1), fixed, and the fix confirmed in
production. H2 and H3 remain open and are recorded as such, and the capture
raised one new finding (0025 C5) rather than closing quietly.

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

### Deviation (b) — 2026-09-04 — H1 confirmed in Phase 2; the fix is taken into this plan

**Found** by Phase 2b, which the plan called "the single most important
artifact" and which went red exactly as it predicted:

```
overlapping start() calls: every armed source is torn down [E]
  Expected: <2>
    Actual: <1>
  both armed sources must be torn down; H1 is real if only one is
```

Two sources armed; **one teardown ran**. `start()`
(`watch_lifecycle.dart:218`) nulls `armedTeardown` (`:167-168`), awaits
`arm(hooks)`, and assigns the new teardown at `:247`. A second `start()`
entering that window tears down nothing, arms a second source, and its
assignment overwrites the first teardown — orphaning a live watcher and leaking
the slot it reserved. Reachable in production because `rearmTimer`, the restart
timer and the recovery timer can each fire during an in-flight arm, and an arm
costs a full SSH round trip.

**H1 is therefore CONFIRMED, deterministically and without the live capture.**
The plan anticipated this exit: *"A red here confirms H1 without needing the
live capture at all, and the plan may stop early and propose the fix."*

**Decision (maintainer): implement the fix under this plan number** rather than
opening a successor. This overrides the plan's own out-of-scope list, which
named "adding a re-entrancy guard to `start()`" as forbidden. That boundary
existed to stop a fix being chosen before a cause was known; the cause is now
known and proven by a test, so the reason for the boundary has expired. Recorded
here rather than applied silently, and the out-of-scope list is annotated at its
source rather than rewritten.

**Consequences for the remaining phases.**

* **Phase 3 (surface the log)** — still wanted. "Why is this repo polling" stays
  unanswerable from inside the app, and the log now has real content to show.
* **Phase 4 (live capture)** — **no longer needed to confirm H1.** Retained in
  reduced form: a post-fix capture to confirm the degraded-poll regime does not
  recur, which is a different question from what caused it.
* **H2 and H3 are neither confirmed nor refuted.** H1 explains every observation
  and is proven; the other two remain plausible contributors that the fix does
  not address. Phase 5 records them as open rather than closed, because a
  hypothesis that was never tested must not be written up as though it were
  eliminated.

### Deviation (c) — 2026-09-05 — the instrument was wired into one of the two watch services

**Reported from use**: watcher lines appear in the output log for repos on the
remote host, and never for repos on this Mac.

Not a difference in watch mechanics, as it first appears. The backend selects
the service (`app_providers.dart:3520-3521`):

```dart
ConnectionBackend.local => local.watch(...)   // LocalWatchService — Directory.watch
ConnectionBackend.ssh   => remote.watch(...)  // RemoteWatchService — inotifywait/fswatch
```

`RemoteWatchService` is constructed **with** a diagnostic channel
(`app_providers.dart:359-368`) and Phase 2 of this plan passed it `onTransition`.
`LocalWatchService` is constructed as `LocalWatchService()` — it has no
`onDiagnostic` parameter at all, and never received `onTransition`. **A local
repo therefore produces no watcher log lines and no transition records, by
construction.** A repo on a *remote macOS host* logs normally; it is
specifically repos on this Mac that are silent.

**Why this is a defect and not a missing nicety.** Both services drive the same
`watchLifecycle`: same restart budget, same degrade-to-polling, same 3-minute
recovery. `LocalWatchService` has its own failure path — some network mounts
reject `Directory.watch()` outright, which it logs and rethrows so the engine
restarts and then degrades (`local_watch_service.dart:227-240`). A local repo
can therefore reach exactly the polling state that
[0027 deviation (b)](0027-PLAN-watcher-reclamation-cannot-reclaim.md) put the
remote host in — **and the diagnostic that exposed that bug would not have
appeared.** Its `developer.log` goes to the IDE console, not the app's output
log, so nothing reaches the user either.

This record's stated purpose is that *"why is this repo polling"* be answerable
from inside the app. For half the backends it was not. Phase 2 wired one service
and the phase was called done.

**Fix:** `LocalWatchService` gains the same `onDiagnostic` parameter, routed to
`outputLogProvider` by the provider, and passes `onTransition` to
`watchLifecycle`; its `Directory.watch` start failure goes to that channel
instead of only to `developer.log`.

**Guarded against recurrence** by a test that arms **both** services and asserts
each feeds `watchDiagnostics` — so the next instrument cannot be wired to one
and declared finished.

**Executed 2026-09-05.** `LocalWatchService` gained `onDiagnostic`, passes
`onTransition`, and reports both its `Directory.watch` start failure and its
stream errors on that channel; `localWatchServiceProvider` routes it to the
output log exactly as the remote one does. Guarded by
`test/watch_diagnostics_both_backends_test.dart`, which arms **both** services
and asserts each feeds `watchDiagnostics` — seen to fail (`Expected: non-empty /
Actual: []`) with the local wiring removed.

**One gap is named rather than papered over.** The local failure paths are wired
but **untested on macOS**: `Directory.watch()` over a path that does not exist
neither throws, nor errors the stream, nor completes it — measured
(`threwSync=false streamError=false done=false`). There is no portable way to
make a local watch fail on demand here, so the `onDiagnostic` calls on those
paths have no covering test.

That measurement also surfaced a hazard worth its own line: **a local watch on a
missing path arms successfully and then reports nothing, forever.** The engine
records `armed`, the indicator shows healthy, and no event can ever arrive —
indistinguishable from a quiet repository. A characterisation test pins it, and
says in its own comment that it pins the behaviour rather than blessing it.
