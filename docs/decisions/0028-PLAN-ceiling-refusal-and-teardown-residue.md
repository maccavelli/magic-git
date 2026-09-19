---
status: "complete"
date: 2026-09-04
associated-madr: "0028-MADR-ceiling-refusal-and-teardown-residue.md"
---

# Make a ceiling refusal recoverable, and settle H3 by observation

Associated MADR: [0028-MADR-ceiling-refusal-and-teardown-residue.md](0028-MADR-ceiling-refusal-and-teardown-residue.md)

## Goal

Close the two watcher hypotheses 0026 left open.

**H2** — a repo refused by the watcher ceiling must arm the moment a slot frees,
instead of polling at 48 host processes per minute until a 3-minute timer
happens to fire; and the four causes of `WatchUnavailable` must be
distinguishable where the difference decides behaviour.

**H3** — determine, by observation under the current build, whether abnormal
channel loss still orphans a host watcher. **No remedy is planned**, because
whether one is needed is unknown.

## Scope

**In scope**

* A typed refusal reason replacing the single `WatchUnavailable`, carrying which
  of the four conditions occurred.
* A slot-release notification so a ceiling-refused repo re-arms promptly.
* Resolving the `static` / "per connection" contradiction on `_liveWatchers` —
  by changing one of them, chosen on evidence in Phase 3.
* One live experiment for H3, and its verdict.

**Out of scope**

* `maxConcurrentWatchers`, `pollInterval`, `recoveryInterval`,
  `leaseStaleAfter`, `heartbeatInterval` — no retuning. H2 is about *reacting*
  to the ceiling, not about its value.
* Any H3 remedy. If Phase 4 produces an orphan, this plan stops and a successor
  decides the fix.
* Admission ordering/fairness between waiting repos (0026 H2-d, declined at a
  ceiling of two).

## Preconditions

```sh
flutter --version | head -1          # must equal FLUTTER_VERSION (3.47.2)
flutter pub get --enforce-lockfile   # "Got dependencies!"
git status --short                   # empty
flutter analyze                      # No issues found!
flutter test                         # 3486 passing, 2 skipped, 0 failing
```

Any deviation from **3486 / 2 / 0**: stop and prompt — the baseline moved.

## Implementation Steps

### Phase 1 — Name the four refusals

**Files.** `lib/core/git/watch_lifecycle.dart`, `lib/core/git/remote_watch_service.dart`;
`test/watch_transition_wiring_test.dart`.

`WatchUnavailable` gains a reason; the engine keeps treating them identically for
now, so this phase is behaviour-neutral and its effect is observable only in the
transition log.

```dart
enum WatchUnavailableReason { noTool, ceiling, streamBudget, noWatchedPaths }
class WatchUnavailable extends WatchArm {
  const WatchUnavailable(this.reason);
  final WatchUnavailableReason reason;
}
```

The four sites (`remote_watch_service.dart:318`, `:345`, `:381`, `:405`) each
pass their own reason — the causes they already record as free text into the
0026 log, now carried where the engine can act on them.

**1a. Negative test.** `degradedToPolling` records the typed reason, not just a
string. **Required red:** the reason is absent before the field exists.

**Acceptance.** Test red then green; **no existing test's expectations change**
(behaviour-neutral); suite +1. **Commit.**

### Phase 2 — Wake a ceiling-refused repo when a slot frees

**Files.** `lib/core/git/remote_watch_service.dart`, `lib/core/git/watch_lifecycle.dart`;
`test/watch_ceiling_recovery_test.dart` (new).

`releaseSlot()` already knows the instant a slot frees; nothing listens. Add a
release notification, and have a watcher that degraded **for the ceiling reason
only** re-arm on it.

**The re-arm must go through `start()`**, which 0026 serialised. A second arming
path is precisely the concurrency shape that produced 0026 H1, and this plan
must not reintroduce it — the wake-up requests an arm, it does not perform one.

**2a. Negative test — the load-bearing one.**

```dart
test('a repo refused by the ceiling arms as soon as a slot frees', () async {
  // fill the ceiling, watch a third repo (refused -> polling),
  // then stop one of the first two
  expect(thirdRepoMode, WatchMode.eventDriven);   // without waiting 3 minutes
});
```

**Required red:** the third repo is still `polling` — today it waits for
`recoveryInterval`. Run under `fakeAsync` so "without waiting" is asserted
rather than raced.

**2b.** A repo refused for a **non**-ceiling reason (`noTool`) must **not** be
woken by a slot release — it would re-probe a host that has not changed.

**Required red:** with the reason ignored, `noTool` re-arms too.

**Acceptance.** Both red then green; suite +2. **Commit.**

### Phase 3 — Resolve the `static` / per-connection contradiction

**Files.** `lib/core/git/remote_watch_service.dart`; `test/watch_ceiling_recovery_test.dart`.

`_liveWatchers` is `static` (`:217`); the constant above it says *"one
connection may hold"* (`:138`). Decide on evidence, and **prompt with the
finding before changing either** — this is a behavioural decision, not a
tidy-up:

* if the budget is genuinely a **host** property, the documentation is wrong and
  the global counter stays — but then two connections to *different* hosts share
  one budget, which needs justifying;
* if it is a **connection** property, the counter must move onto the service
  instance and the ceiling applies per connection.

**3a.** Whichever is chosen, a test pins it: two services either do or do not
share the budget, asserted explicitly rather than left implicit.

**Acceptance.** Decision recorded here with its rationale; test red then green.
**Commit.**

### Phase 4 — H3: try to produce an orphan under the current build

**No code.** An experiment, whose result is the deliverable.

1. Census the host: watcher trees, pids, ages.
2. Arm a watcher against a scratch repo on the host.
3. Kill the SSH channel **abnormally** — drop the transport without a clean
   teardown, the 0022 M5 condition. Not `sub.cancel()`, which is the path
   already known to work.
4. Observe for `leaseStaleAfter` + one `inotifywait -t` wake (≈7 minutes),
   sampling every 30 s.
5. Record whether the host process is gone, and when.

**Pre-committed reading**, so the result is not fitted afterwards:

| observation | verdict |
|---|---|
| process gone within ~7 min | **H3 resolved by consequence** of 0026 + 0027; record with evidence and close |
| process still alive after ~10 min | **H3 confirmed and open**; this plan stops, a successor decides the remedy |
| no orphan could be produced at all | inconclusive — record the method that failed; do **not** read it as resolution |

**Acceptance.** The census, the method, and the timings recorded verbatim; the
scratch repo removed; no stray processes left behind. If an orphan survives, it
is left in place as a fixture **only** with the maintainer's agreement — 0027
showed a pre-fix orphan can be irrecoverable.

### Phase 5 — Record the outcome

Write both verdicts into this plan and into the MADR's **Confirmation**. If H3
is confirmed open, propose the successor; if resolved, amend 0026 so its "open,
not eliminated" note is closed with evidence rather than left dangling.

## Verification

**Per phase:** the phase's own tests, plus

```sh
flutter analyze          # No issues found!
flutter test             # passing rises by exactly the tests added; failing 0
```

**Whole-plan acceptance.**

1. Every negative test observed red, verbatim, in the execution record.
2. `flutter analyze` clean; `flutter test` 0 failing throughout.
3. Phase 1 changed no existing test's expectations.
4. The ceiling wake-up goes through the serialised `start()` — no second arming
   path (a reviewer can check by grepping for callers of the arm).
5. Phase 4's verdict read from the pre-committed table, not fitted to the result.
6. Nothing from the out-of-scope list touched; no interval or ceiling retuned.
7. Host left clean.

## Rollout and Rollback

Phases 1–3 are confined to the watcher's arming path; rollback is reverting the
phase commits, and nothing persists on a host. Phase 4 creates a scratch repo
and one watcher, both removed.

The risk that matters is **concurrency**, not correctness of the ceiling: this
plan adds a wake-up to the component whose last two defects were both
concurrency-shaped (0026 H1's unguarded `start()`, and the check-then-act in the
ceiling reservation that 0025 Phase 3 had to fix with reserve-then-arm). The
mitigation is structural — the wake-up *requests* an arm through the existing
serialised path and never arms directly — and criterion 4 exists to enforce it.

## Execution record

*(Empty until approved.)*

| Phase | Status | Commit | Red-test observed | Result |
|---|---|---|---|---|
| 1 | executed | `af8ea52` | `Expected: contains 'ceiling' / Actual: 'arm unavailable'` | the four refusals are typed |
| 2 | executed | `dd62a36` | `Expected: eventDriven / Actual: polling` | a ceiling-refused repo arms on slot release |
| 3 | executed (corrected) | `854d7a0` | `Expected: polling / Actual: eventDriven` (ceiling raised) | assumption stated and pinned; see deviation (a) |
| 4 | executed | — | n/a (live experiment) | **H3 resolved by consequence** — abandoned watcher self-terminated at 371 s |
| 5 | executed | *(this entry)* | — | both verdicts recorded |

### Phase 2 as executed — the wake-up, and its guard

`releaseSlot()` now broadcasts, and a watcher that degraded **for the ceiling
reason only** re-arms on it. Red observed with no time advanced at all, so a
green cannot be the 3-minute recovery timer firing:

```
Expected: WatchMode:<WatchMode.eventDriven>
  Actual: WatchMode:<WatchMode.polling>
```

The reason guard is load-bearing and was seen to fail: removing it makes a
`noTool` refusal re-probe on every slot release (`Expected: <1> / Actual: <2>`).
Acceptance criterion 4 holds — `grep` finds exactly one call to `arm(hooks)`
(`watch_lifecycle.dart:337`, inside `startOnce`), so the wake-up requests an arm
through the serialised path and never opens a second one.

### Phase 4 as executed — H3, and a first attempt that had to be thrown away

**Verdict: H3 is resolved by consequence of 0026 and 0027.** Read from the
plan's pre-committed table (*"process gone within ~7 min"*), not fitted
afterwards.

An abandoned watcher — armed with a fresh lease, then its client removed with no
clean teardown, nothing ever refreshing the lease again — self-terminated at
**lease age 371 s**, inside the predicted 360-480 s window. The mechanism is
visible in the samples rather than inferred: the `inotifywait` child pid rotates
at t≈135 s and t≈270 s, which is `-t 120` waking and the loop re-arming, with
the lease re-checked at each wake (146 s, 281 s — both fresh) and the third wake
finding it stale.

```
t≈0s   ALIVE  child=182260 (age 10s)   lease age=11s
t≈135s ALIVE  child=182413 (age 25s)   lease age=146s     <- first -t wake, re-armed
t≈270s ALIVE  child=182571 (age 40s)   lease age=281s     <- second wake, re-armed
t≈360s GONE — self-terminated at lease age 371s
```

**The first attempt was invalid and is recorded rather than quietly replaced.**
It wrote the watcher's output to a log **inside the directory being watched**,
so every event wrote a line that generated another event: 178,933,852 lines and
**1.78 GB** on the host, `inotifywait -t 120` never saw 120 s of silence, the
lease was therefore never re-checked, and the watcher was still alive at 419 s.
Read naively that was a confirmation of H3 — the opposite of the truth. It was
caught by checking the instrument rather than the result. The file was deleted
(`/tmp` 51% → 8%) and one `inotifywait` my own cleanup orphaned was killed.

A second invalid check was also caught: an instrument probe whose redirect
failed because its log directory did not exist yet reported "exited within 25s"
having never started at all. The corrected probe verified the process was
running before timing it, and observed `-t 20` firing after ~18 s on a quiet
directory.

**Incidental confirmation.** The app disconnected during the phase, and its own
lease shells were gone with zero orphans left behind — the lease doing exactly
its job once the client is truly absent.

### Verdicts

* **H2 — confirmed and fixed.** A ceiling refusal was indistinguishable from a
  permanent host limitation and answered with the same 3-minute recovery; a
  third watched repo therefore polled at 48 host processes per minute until a
  timer happened to fire, or forever while the slots stayed occupied. The
  refusals are now typed, and a ceiling-refused repo takes a freed slot at once.
* **H3 — resolved by consequence, with evidence.** 0026's serialised arming
  removed the route that manufactured orphans, and 0027's per-instance lease
  means an orphan's own lease goes stale on schedule. Measured: 371 s. **No
  remedy was needed and none was built** — which is what "measure first" was
  for.
* **The `static` ceiling scope — no defect.** See deviation (a): the app holds
  one connection at a time, so the two comments describe the same set, and the
  remedy the MADR floated would have multiplied the ceiling. Now stated and
  pinned.

0026's H2/H3 are closed. Its "open, not eliminated" note can be read as
discharged.

## Deviations

### Deviation (a) — 2026-09-04 — Phase 3's premise was wrong: there is no behavioural defect

**Found** at the start of Phase 3, before changing anything. The MADR asserts
that `_liveWatchers` being `static` (`remote_watch_service.dart:217`)
contradicts the constant's *"one connection may hold"* (`:138`), and that one of
them must be a defect. The code says otherwise:

* `connectionProvider` (`app_providers.dart:2727`) is a plain
  `NotifierProvider`, not a family, and `remoteWatchServiceProvider` (`:360`) is
  a plain `Provider`. **The app holds one connection at a time.** "Process
  global" and "per connection" therefore describe the same set of watchers, and
  both comments are individually accurate.
* The remedy the MADR floated — moving the counter onto the service instance —
  would be a **regression**, not a fix. The counter's own comment records why it
  is static: *"several providers construct their own service against the same
  host"*. Per-instance counting would give each service its own budget of two
  and multiply the ceiling instead of enforcing it.

So the contradiction is documentary: neither comment states the assumption it
depends on, which makes the pairing read as a defect and *would* become one if
simultaneous connections ever landed.

**Decision (maintainer): state the dependency and pin it with a test.** Keying
the counter by host was considered and declined as speculative work on a
condition the app cannot currently reach, in a component whose last three
defects were all concurrency-shaped. Dropping Phase 3 entirely was declined
because it leaves the misleading pairing in place with nothing to catch a future
multi-connection change.

**MADR 0028 carries the correction as amendment 0028.1.**
