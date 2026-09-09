---
status: "executed"
date: 2026-09-09
associated-madr: "0040-MADR-the-watcher-ceiling-is-the-wrong-limit.md"
---

# Implement the watcher ceiling decision

Associated MADR: [0040-MADR-the-watcher-ceiling-is-the-wrong-limit.md](0040-MADR-the-watcher-ceiling-is-the-wrong-limit.md)

Line numbers are as of `a397434`. Re-run the proof block below before starting;
if any has moved, re-anchor rather than trusting a number. **Every search claim
here uses `grep -a`** — `app_providers.dart` is classified binary and a plain
`grep` returns zero matches on it.

## Goal

Stop a two-watcher cap forcing every repository past the second onto a polling
fallback that costs ~48 git processes per minute, and make the cap's bookkeeping
incapable of drifting:

1. no arm failure can strand a reserved slot;
2. the cap is derived from the transport budget it exists to respect, keyed to
   the thing that actually owns that budget;
3. the count is reconciled against reality on every connect, so bookkeeping that
   goes wrong for a reason nobody anticipated heals by itself.

## Scope

**In scope.** `lib/core/git/remote_watch_service.dart`,
`lib/core/git/bounded_watch.dart` (the sweep script only),
`lib/core/providers/app_providers.dart` (`remoteWatchServiceProvider`), and the
tests named per phase.

**Out of scope, deliberately.**

* **`pollInterval`.** Making the degraded state cheaper is not the goal; making
  it rarer is. It is also *worse* than watching — a poll cannot see a change made
  and reverted between ticks.
* **Selecting the watch surface by measured disproportion** (bounded watch for
  large ordinary repositories). Real, and named in MADR amendment 0040.1, but a
  change of shape that needs its own record. The repository that motivated it is
  no longer in the working set.
* **Consulting the host's remaining inotify budget before arming.** Speculative
  since amendment 0040.1: the remaining fourteen repositories total 858
  directories, 0.16 % of the budget.
* **`maxConcurrentStreams` itself.** 8 is inside this host's `MaxSessions 10`
  and is not what is binding.

## Prerequisites

```sh
flutter --version | head -1          # must be 3.47.2 (build_macos.sh:41)
flutter pub get --enforce-lockfile   # must print "Got dependencies!"
flutter analyze                      # clean before anything is edited
flutter test                         # green before anything is edited
git status --porcelain               # only test/watch_slot_leak_test.dart (untracked)
```

`test/watch_slot_leak_test.dart` already exists and **fails** — it is the
evidence for F8 and becomes Phase 1's regression guard. It is the one expected
dirty entry.

## Proof of the MADR's assertions

Run before starting; paste the output into the execution record.

```sh
# F3 — the two limits, and the fact that nothing connects them.
grep -n 'maxConcurrentWatchers = ' lib/core/git/remote_watch_service.dart   # 2
grep -n 'int get maxConcurrentStreams' lib/core/ssh/ssh_command_executor.dart  # 8 / 2
grep -rn 'maxConcurrentStreams' lib/core/git/                               # no hits: unconnected

# F8 — five ways to fail the stream open, one of them caught.
grep -n 'throw SSH' lib/core/ssh/ssh_command_executor.dart | awk -F: '$1>1200 && $1<1290'
grep -n 'on SSHStreamBudgetExhausted' lib/core/git/remote_watch_service.dart
flutter test test/watch_slot_leak_test.dart   # MUST FAIL: 4 tests, one slot lost each

# F8 — pre-existing, not from the 0039 series.
git log -1 --format='%h %ad' --date=short -S'on SSHStreamBudgetExhausted catch (e)' \
  -- lib/core/git/remote_watch_service.dart    # d10a334 2026-09-04
git log -1 --format='%h %ad' --date=short -S'var armCounted = true;' \
  -- lib/core/git/remote_watch_service.dart    # 7735f13 2026-09-04

# The three long-lived stream consumers the headroom is reserved for.
grep -rn 'executeStream(' lib --include=*.dart \
  | grep -v '_command_executor.dart'           # glab trace, clone, watcher
```

On the host (maintainer, and only if the question comes up again — the answers
are already in the MADR):

```sh
ssh <user>@<bastion> 'pgrep -af "inotifywait|mg-watch"; \
  find /home/<user>/gitrepos -name "mg-watch.*" | wc -l; \
  cat /proc/sys/fs/inotify/max_user_watches'
```

## Working rules for execution

* One commit per phase, `git commit --no-edit` only — `AGENTS.md` forbids writing
  message text and a `prepare-commit-msg` hook generates it. **Docs and code in
  separate commits**: a commit mixing them makes the hook summarise the plan
  instead of the diff (MADR 0039 plan, deviation D4).
* Never `git push` unless asked in that turn.
* `flutter analyze` and `flutter test` clean before every `git add`.
* Every new check seen to fail first, via
  `tool/mutations/0040-watcher-ceiling.json`. **Run the whole catalogue at each
  phase boundary**, not just the phase's slice — a later phase can un-arm an
  earlier phase's mutation by reformatting its anchor (0039 plan, D9).
* Any deviation stops execution and prompts.

## Phase ordering

| Phase | Finding | Depends on | Droppable |
|---|---|---|---|
| 1 Structural slot release | F8 | — | no |
| 2 Derive the cap from the stream budget | F3, F4 | — | no — this is the one the maintainer can see |
| 3 Reconcile at the connect sweep | F1, F8 | 1, 2 | yes, but it is the belt to Phase 1's braces |

Phase 2 is the only phase that changes observable behaviour. Phases 1 and 3 make
the cap trustworthy; without Phase 2 the ticket does not close.

---

## Implementation Steps

### Phase 1 — No arm failure can strand a slot (F8)

**Goal.** The reservation is released on *every* exit from the arm, including
exception types nobody has thought of.

**Files.** `lib/core/git/remote_watch_service.dart`;
`test/watch_slot_leak_test.dart` (exists, currently failing).

**Steps.**

1. In `watch`'s `arm` callback, wrap everything from the reservation
   (`remote_watch_service.dart:405`) to the `return WatchArmed(...)` in a
   `try { … } catch (_) { releaseSlot(); rethrow; }`.
   * The success path still does **not** release — `WatchArmed`'s teardown owns
     that, and the `armCounted` flag already makes a double release a no-op.
   * `rethrow`, not swallow: the lifecycle engine's `start().catchError(…)`
     turns a throw into a scheduled restart, which is the correct response to a
     transport blip. Converting it to `WatchUnavailable` here would spend the
     restart budget differently and is a behaviour change this phase does not
     want.
2. **Keep the four existing explicit `releaseSlot()` calls.** They are not
   redundant: each pairs the release with a distinct `_record(...)` cause and a
   distinct `WatchUnavailable` reason, which is what makes
   `degradationSummary` legible. The catch-all is the backstop for everything
   *else*.
3. Extend the `on SSHStreamBudgetExhausted` comment to say why that one branch
   stays distinct — it is the only *deterministic* failure, so it must not be
   retried (0024 M2), where the others are blips that should be.

**Tests.** `test/watch_slot_leak_test.dart` already asserts the contract for
`SSHCommandSuperseded`, `SSHTransportNotReady` and `SSHCommandTimeout`, plus the
budget-exhaustion case. Add `SSHChannelOpenError` — the fifth, and the one a
bastion under `MaxSessions` pressure produces.

**Mutations** (`tool/mutations/0040-watcher-ceiling.json`):
* `p1 catch-all removed` — delete the `catch`/`rethrow`.
* `p1 catch swallows` — `catch` without `rethrow`, so a blip silently becomes a
  successful-looking arm with no watcher.

**Verification.**

```sh
flutter analyze
flutter test test/watch_slot_leak_test.dart test/remote_watch_service_test.dart \
             test/watch_ceiling_recovery_test.dart test/watch_ceiling_per_host_test.dart
flutter test
tool/mutate.py tool/mutations/0040-watcher-ceiling.json --only p1
```

**Acceptance.** All five failure modes release the slot; both mutations killed;
the four pre-existing explicit release paths keep their distinct causes —
assert the `armFailed` cause strings are unchanged.

---

### Phase 2 — The cap comes from the transport budget (F3, F4)

**Goal.** One number, derived, keyed to what owns it.

**Files.** `lib/core/git/remote_watch_service.dart`,
`lib/core/providers/app_providers.dart` (`remoteWatchServiceProvider`),
`test/watch_ceiling_per_host_test.dart` (amend),
`test/watch_ceiling_derived_test.dart` (new).

**Steps.**

1. Replace `static const int maxConcurrentWatchers = 2` with a derived value.
   Add a `int Function()? streamBudget` constructor callback beside the existing
   `hostKey` — a callback for the same reason, so a degrade/redial changes the
   answer without rebuilding the service and restarting every live watcher:

   ```text
   cap = max(1, streamBudget() - reservedStreams)
   reservedStreams = 2   // the CI job trace and clone progress
   ```

   Healthy triple client: `8 - 2 = 6`. Degraded onto the command client:
   `2 - 2 = 0`, floored to **1** — a single-client session still watches the
   repository the user is looking at.
2. Keep the name `maxConcurrentWatchers` as a *getter*, so every existing
   reference and diagnostic reads unchanged.
3. `remoteWatchServiceProvider` passes
   `streamBudget: () => ref.read(executorProvider).maxConcurrentStreams`.
   `ref.read` inside a closure, never `ref.watch` — the same rule the `hostKey`
   wiring already follows and for the same reason.
4. Key the counter by **(session, host)**, not host alone. The channel budget is
   per connection and each tab has its own; the process budget is per host and
   the lease now guards it (F2). `_liveByHost` becomes keyed by the record
   `(Object scope, String host)`, with the scope supplied from
   `sessionScopeProvider` exactly as MADR 0039 F1–F5 do. `liveWatchers` stays as
   the cross-everything total for diagnostics; add `liveWatchersFor(scope, host)`.
5. Rewrite the class doc: name both numbers, say the transport enforces the real
   one at `executeStream` and this is a *derived* courtesy limit, and record that
   the orphan problem it originally existed for is now the lease's job (F2).

**Tests.**

`test/watch_ceiling_derived_test.dart` (new):
* a healthy budget of 8 yields a cap of 6;
* a degraded budget of 2 yields **1**, not 0 — the floor, asserted explicitly,
  because a cap of 0 silently disables watching entirely;
* the cap follows the budget when it changes mid-session (degrade then redial),
  which is what the callback exists for;
* arms past the derived cap still degrade to polling with the `ceiling` cause.

`test/watch_ceiling_per_host_test.dart` (amend): its five existing tests must
keep passing, with the addition that **two sessions on one host now get their own
budgets** — the behaviour change — while **two hosts still do**.

**Mutations.**
* `p2 cap hardcoded again` — the getter returns a literal 2.
* `p2 floor removed` — the `max(1, …)` drops, so a degraded session gets 0.
* `p2 headroom removed` — `reservedStreams` becomes 0, so watchers can starve
  the CI trace and clone streams.
* `p2 key ignores the session` — the counter reverts to host-only.

**Verification.**

```sh
flutter analyze
flutter test test/watch_ceiling_derived_test.dart test/watch_ceiling_per_host_test.dart \
             test/watch_ceiling_recovery_test.dart test/watch_transition_wiring_test.dart \
             test/remote_watch_service_test.dart test/watch_lifecycle_test.dart
flutter test
tool/mutate.py tool/mutations/0040-watcher-ceiling.json --only p2
```

**Acceptance.** Four mutations killed; `watch_lifecycle.dart` unmodified
(`git diff --stat` must not list it); `remote_watch_service_test.dart`'s
`expect(RemoteWatchService.maxConcurrentWatchers, 2)` is **updated, not deleted**
— it becomes an assertion about the derivation, and the comment says what it used
to pin and why that is no longer the contract.

---

### Phase 3 — The count reconciles against reality (F1, F8)

**Goal.** Bookkeeping that goes wrong heals at the next connect instead of
persisting for the session.

**Design note.** Reconciliation is scoped to **this session's own repositories**,
which is all a session can honestly claim. The counter is meant to equal the
number of arms this session currently holds; the sweep already walks each
repository's `mg-watch.*` registry files at connect, so it can report which of
this session's watcher tokens the host still has, and the service drops the rest.
It cannot and must not reconcile against watchers belonging to another tab.

**Files.** `lib/core/git/remote_watch_service.dart`,
`lib/core/git/bounded_watch.dart` (`watcherSweepScript`),
`test/watch_reconcile_test.dart` (new), `test/watch_lease_identity_test.dart`
(amend if the script's output shape is asserted there).

**Steps.**

1. Track live arms as a **set of tokens** per `(scope, host)` rather than an
   integer. The count becomes `set.length`, so it cannot drift from the identity
   of what is held, and a reconciliation has something to match against.
2. Extend `watcherSweepScript` to print, per repository, the tokens whose
   heartbeat is still fresh — it already stats those files to decide what to
   reclaim, so this is output, not extra work.
3. In `sweepStaleWatchers`, collect the reported tokens and drop from the
   session's set any token the host no longer reports. Release announcements fire
   for each drop, so a repository waiting on the ceiling takes the freed slot
   immediately (0028 H2).
4. Best-effort, exactly as the sweep already is: a failure here must never affect
   the connect.

**Tests.** `test/watch_reconcile_test.dart`:
* a token the host no longer reports is dropped and the slot announced;
* a token the host **does** report is left alone — the guard against a
  reconciliation that "fixes" a correct count by zeroing it;
* a sweep failure leaves the count untouched rather than clearing it;
* reconciliation touches only the calling session's set.

**Mutations.**
* `p3 reconcile clears everything` — drops all tokens regardless of the report.
* `p3 reconcile ignores the report` — a no-op, so a leak persists.
* `p3 sweep failure zeroes the count`.

**Verification.**

```sh
flutter analyze
flutter test test/watch_reconcile_test.dart test/watch_lease_identity_test.dart \
             test/remote_watch_service_test.dart test/bounded_watch_test.dart
flutter test
tool/mutate.py tool/mutations/0040-watcher-ceiling.json --only p3
```

**Acceptance.** Three mutations killed; the sweep stays best-effort (a thrown
sweep does not fail a connect — assert it); host-side script changes covered by
`test/host_scripts_test.dart` if that is where the sweep script is executed for
real (MADR 0029's rule: a host script that no test executes is not tested).

---

## Verification (whole plan)

```sh
flutter --version | head -1
flutter pub get --enforce-lockfile
flutter analyze
flutter test
tool/mutate.py tool/mutations/0040-watcher-ceiling.json
git status --porcelain
git log --oneline master..HEAD
```

### Sabotage

Every check introduced here must be observed failing against a deliberately
broken input in the harness's scratch worktree, and the failure recorded. Phase 1
starts with a test that already fails, which is the strongest form of that.

### Manual verification on the host (maintainer)

After Phase 2, with a rebuilt app — note that the reported build predates all of
this (F9), so **a rebuild is required for any of it to be visible**:

1. Open more than two repositories from the collections directory in one tab.
   Each should show the live watch indicator, not the polling one.
2. On the host: `pgrep -af inotifywait` shows one logical watcher per opened
   repository (parent shell → subshell → `inotifywait`; count *parents*), and
   `find … -name 'mg-watch.*' | wc -l` is exactly twice the number of live
   watchers.
3. Close the tab. Within five minutes every one of those watchers has exited on
   its own lease, and the registry files are gone.
4. With a second tab on the same host, both tabs should hold their own watchers —
   the F4 behaviour change.

### Acceptance criteria (whole plan)

1. `flutter analyze` clean and `flutter test` green at every phase boundary.
2. Every mutation killed, no `DID-NOT-APPLY` anywhere in a full-catalogue run.
3. `test/watch_slot_leak_test.dart` passes, having been seen to fail first.
4. No arm failure path can strand a slot; no session can be refused a watcher
   while the transport would still grant it a stream.
5. `grep -rn 'maxConcurrentWatchers = 2' lib/` returns nothing, and the cap's one
   remaining literal is the reserved-stream headroom.
6. The four pre-existing `armFailed` cause strings are unchanged, so
   `degradationSummary` still reads the way MADR 0026 designed it.
7. Every deviation recorded here with its date, evidence, and the resolution
   chosen — original steps struck through, not rewritten.

## Rollout and Rollback

No migration, no persisted format change, no host-side state change: the sweep
script gains output but reclaims exactly what it reclaimed before. Each phase is
one commit and independently revertable with `git revert`. Reverting Phase 2
alone restores the cap of 2 without disturbing Phases 1 and 3.

The archival repository's `.git` → `_git` rename (MADR amendment 0040.1) is a
host-side data change made by the maintainer, outside this plan and outside its
rollback; it is undone with `mv _git .git` in that directory.

## Execution record

**All three phases executed 2026-09-09**, one commit each, unpushed. The
maintainer's build predates every one of them (F9), so **a rebuild is required
before any of this is visible**.

### Baselines

| | before | phase 1 | phase 2 | phase 3 |
|---|---|---|---|---|
| `flutter analyze` | clean | clean | clean | clean |
| `flutter test` | 3892, 3 skipped | 3897 (+5) | 3904 (+7) | 3911 (+7) |
| mutations | — | 2/2 | 7/7 | 12 of 12, 0 survived, 0 did not apply |

### Phase 1 — structural slot release

The arm is wrapped from the reservation to the `WatchArmed` return in
`try { … } catch (_) { releaseSlot(); rethrow; }`. The four explicit releases
stay, each keeping its distinct `_record` cause — verified unchanged
(`no watcher tool`, `ceiling n/m`, `stream budget`, `no watched paths`), so
`degradationSummary` reads as MADR 0026 designed it. `rethrow` rather than
degrade, so a blip still becomes a scheduled restart.

`test/watch_slot_leak_test.dart` was **already failing** when the phase began —
the strongest form of "seen to fail first" — and now covers all five ways
`executeStream` can fail, including `SSHChannelOpenError`.

### Phase 2 — the cap is derived

`maxConcurrentWatchers` became a getter: `max(1, streamBudget() - 2)`. Healthy
triple client 6, degraded 1, unwired 1. `reservedStreams = 2` is the only literal
left, and it names the CI trace and clone streams it holds back. The counter is
keyed `(scope, host)`, and release announcements are keyed the same way.

### Phase 3 — reconciliation

The counter became a **set of tokens**, so the count is `.length` and cannot
drift from the identity of what is held. `watcherSweepScript` gained a read-only
final loop that prints `LIVE <token>` per fresh lease; `sweepStaleWatchers`
collects those and drops any of **this session's** tokens the host does not
report. A failed sweep reconciles nothing — `reported` stays null — because "no
answer" is not "nothing is live".

### Sabotage

`tool/mutations/0040-watcher-ceiling.json`, 12 entries: **12 killed, 0 survived,
0 did not apply.**

### Deviations

**D1 — 2026-09-09 — the conservative default changed what every existing ceiling
test exercised.** An unwired service now derives a cap of 1, not 2, so
`watch_ceiling_recovery_test`, `watch_transition_wiring_test`,
`watch_ceiling_per_host_test` and `remote_watch_service_test` were all written
against a cap they no longer got. *Resolution:* keep the conservative default —
a caller that forgets should get less than a degraded connection could carry, not
more — and make each test **state the budget it exercises**
(`streamBudget: _budgetFor2`). The tests are better for it: their premise is now
written down instead of inherited from a constant.

**D2 — 2026-09-09 — `remote_watch_service_test`'s "the ceiling is a named
constant" pinned exactly what this changes.** Amended, not deleted, per the
plan's acceptance criterion: it now asserts the *derivation* (8 → 6, 2 → 1) and
its comment says what it used to pin and why that is no longer the contract.

**D3 — 2026-09-09 — a phase 2 mutation survived because the release
announcement's effect is invisible to a mode assertion.** `p2: the release
announcement ignores the session` survived: a session woken by a slot it cannot
use is simply refused again, so its mode stays `polling` either way. Counted the
wasted `armFailed(ceiling …)` transitions instead — the same instrument MADR
0039's `watch_ceiling_per_host_test` reached for, for the same reason. Also
required giving the two tabs **distinct repo paths**, since `watchDiagnostics` is
keyed by path alone and both tabs watching `/two` filed into one log.

**D4 — 2026-09-09 — `assertion_strength_scan_test` caught the phase 3 tests
asserting on generated script text without executing it.** MADR 0029's guard,
working exactly as intended. *Resolution:* move the contract to
`watcher_sweep_exec_test.dart`, which **runs** the script — a live token and a
stale one in a temp directory, asserting the fresh one is reported, the stale one
is not, and the stale one is still reclaimed. The Dart half (parsing `LIVE`
lines) stays in `watch_reconcile_test.dart`, with a comment saying where the
behaviour is asserted and why.

Worth recording that the first attempt at this deviation **removed** the text
assertions before adding the executing one, leaving the reporting briefly
untested; the gap was caught by re-reading the diff rather than by a check.

### Not done

* **The manual host verification** in this plan's Verification section. It needs
  a rebuilt app, which is the maintainer's step.
* Everything under Scope's "out of scope, deliberately" — unchanged.
