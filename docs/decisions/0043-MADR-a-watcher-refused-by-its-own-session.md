---
status: "accepted"
date: 2026-09-10
decision-makers: [Maintainer]
consulted: []
informed: [Magic Git contributors]
verified: 2026-09-09
---

# One session can arm two watchers on one repository, and the host lock refuses the second — so a healthy repository polls because of a collision with itself

## Context and Problem Statement

Within hours of [MADR 0041](0041-MADR-the-watcher-the-client-cannot-kill.md)
shipping, the maintainer reported this from a running build:

```text
watcher: another live watcher already holds <repo> — polling here
watcher: polling <repo> — arm unavailable: heldByAnother; watchers held 1,
  restarts spent 0  after: armed(arm succeeded) -> armFailed(held by another watcher)
watcher: another live watcher already holds <repo> — polling here
```

`heldByAnother` is new — it is MADR 0041 phase 3's host-side `mkdir` lock
refusing a second watcher for one repository. The lock is doing exactly what it
was built to do. The question this record answers is **who the "other" watcher
was**, because the answer determines whether this is the feature working or a
defect wearing its clothes.

It is a defect. **There was only ever one session.** The maintainer confirmed
one remote tab and two local tabs, and no second copy of the app; a host census
found exactly one SSH connection group — the three `notty` sessions of a single
tab's triple-client — and one live watcher. Nothing else was ever there to
compete.

So the second watcher belonged to the same session as the first. The client
armed a repository twice, and its own host-side lock told it no.

MADR 0041 F12 anticipated the cross-session case and built the lock for it. What
it did not anticipate is that **nothing at the client level prevents one session
from arming the same repository twice**, which turns the lock from a backstop
into the only line of defence — and makes its refusal, in this case, pure loss:
a repository that could have been watched polls instead, for no reason but a
collision with itself.

## Findings

### F1 — The diagnostic ordering proves two watchers coexisted; it cannot be one watcher restarting

This is the finding the whole record turns on, and it is readable directly from
the four words that are *missing*.

`degradationSummary` (`watch_diagnostics.dart`) prints up to four transitions
preceding a `degradedToPolling`. It printed exactly two:

```text
armed(arm succeeded) -> armFailed(held by another watcher)
```

`armed` and `armFailed` are **adjacent**. Every path that re-arms an existing
`watchLifecycle` records a transition of its own *before* calling `start()`:

| Re-arm path | Records first | Source |
| --- | --- | --- |
| `hooks.rearm()` | `rearmed` | `watch_lifecycle.dart` |
| `scheduleRestart` → `restartTimer` | `restartScheduled` | `watch_lifecycle.dart` |
| `startPolling`'s `recoveryTimer` | `recoveryAttempted` | `watch_lifecycle.dart` |
| slot-release wake (`slotSub`) | `recoveryAttempted` | `watch_lifecycle.dart` |
| `onListen` | — but fires once per controller | `watch_lifecycle.dart` |

And `stop()` records `stopped` as its **first statement**, before it touches
anything:

```dart
Future<void> stop() async {
  onTransition?.call(WatchTransition.stopped, 'stream cancelled', restarts);
  cancelled = true;
  …
```

So one instance re-arming itself would show `armed → restartScheduled →
armFailed`, or `armed → rearmed → armFailed`, or `armed → recoveryAttempted →
armFailed`. One instance being replaced by another would show `armed → stopped →
armFailed`.

**None of those is what happened.** `armed` sits directly against `armFailed`,
which leaves exactly one shape: the instance that recorded `armed` was **still
running, never stopped**, when a *second* instance recorded `armFailed`.

Two watchers for one repository, coexisting, inside one session.

That they land in one log is not a coincidence — `watchDiagnostics` is keyed by
bare `repoPath` with no session or instance identity, so two instances watching
one path write into the same `WatchTransitionLog`. The conflation is what makes
the adjacency visible at all.

### F2 — Reproduced: `RemoteWatchService` has no same-path guard, and arms as many watchers as it is asked to

The gap F1 implies is not subtle, and it needs no host to demonstrate. One
service, one repository path, two concurrent subscriptions:

```dart
final service = RemoteWatchService(exec, hostKey: () => 'host',
                                   streamBudget: () => 8);
final a = service.watch('/repo').listen((_) {});
final b = service.watch('/repo').listen((_) {});
```

Measured:

```text
distinct watchers armed for ONE repoPath: 2
tokens: [hm5fn0zijz0, hm5fn0zj041]
slots held: 2

diagnostic records for /repo:
  armed(arm succeeded)
  armed(arm succeeded)
```

**Two watchers, two tokens, two reserved slots, two `armed` records — for one
repository.** Nothing in `RemoteWatchService.watch()` asks whether this path is
already being watched, and nothing serialises a new arm against a prior one's
teardown. `watchLifecycle`'s `startChain` serialises arms *within* one instance
(MADR 0026 H1's fix) and has no visibility across instances.

Against a fake executor both arms succeed, as above. Against a real host the
second one's script reaches the `mkdir` and exits 98 — turning the second
`armed` into `armFailed(held by another watcher)`, **which is precisely the
record pair in F1.** The observed diagnostic is the direct consequence of this
gap.

### F3 — A Riverpod rebuild arms the new stream before the old teardown finishes

One concrete mechanism that produces overlap, demonstrated deterministically
against a provider mirroring `repoWatchProvider`'s shape — an
`autoDispose.family` whose stream arms on listen and tears down asynchronously
on cancel — invalidated exactly as `_invalidateRepoState()` does it
(`ref.invalidate(repoWatchProvider)`):

```text
arm-start:1
arm-done:1
--- forcing rebuild ---
teardown-start:1
arm-start:2        <- the new arm begins …
arm-done:2         <- … and COMPLETES …
teardown-done:1    <- … before the old teardown finishes
```

The new generation arms and completes entirely inside the old generation's
teardown window. Applied to the real provider, generation 2's `arm()` — with its
own fresh token — would run its `mkdir` while generation 1's watcher still holds
the lock.

**This is not what happened in the observed incident**, and the record should
say so plainly: this ordering fires `onCancel` (and therefore records `stopped`)
*before* the new arm, and F1's log has no `stopped`.

Both rebuild routes were measured and both order the same way — `invalidate()`
on the provider itself, and a change to a watched dependency:

```text
teardown-start:1     <- onCancel first, in BOTH cases
ARM-start:2
ARM-done:2
teardown-done:1
```

So **no Riverpod rebuild can produce F1's record pair**, because every one of
them records `stopped` before the new arm. That narrows F9 usefully: the second
subscription was not a replacement for the first, it was *concurrent with* it.
Two live subscriptions, both wanted, at the same time.

The route is included because it is a second, independently reachable way to
collide — the new arm completes entirely inside the old teardown's window — and
any fix must close it too.

### F4 — The host lock releases quickly; the window is real but short

Measured on the reporting host, after correcting a defect in the measurement
itself (F5). A watcher holding the lock, its client's channel closed cleanly —
the `handle.cancel()` case:

* lock gone at **t+0.73 s** in a polling run that checked at 0.73 s intervals
  (so: released somewhere in the first 730 ms);
* already gone by the time a fresh acquisition attempt's SSH round trip landed
  (~230 ms) in two further runs, both over a reused multiplexed connection and a
  cold one.

So the stdin-EOF watchdog from MADR 0041 F11 works, and works promptly, for a
graceful channel close and not only for the abrupt `SIGKILL` its original probe
used. The release window is sub-second.

Sub-second is not zero. `teardownWatcher()` awaits `handle.cancel()`, which
resolves when the **local** session is closed — it does not wait for the remote
process to notice EOF, run its trap, and `rm -rf` the lock. Any arm that reaches
the host inside that window finds a lock whose owner's heartbeat is, by
construction, freshly refreshed — so the steal branch correctly declines to
steal, and the arm is refused.

### F5 — Correcting a measurement error in this investigation

The first pass at F4 reported the lock still held **19 seconds** after the
channel closed, which read as MADR 0041's central fix failing for the ordinary
teardown path. That was wrong, and it was wrong because of a defect in the probe,
not in the product: the lease-loop script was assembled in a Python f-string
whose nested shell quoting (`\\\"$L/token\\\"`) did not survive into the command
actually sent. Rebuilt as a file and shipped verbatim with `scp`, the identical
scenario released the lock in 0.73 s.

Recorded because the erroneous number briefly drove the diagnosis toward a much
larger and entirely fictional conclusion, and because the correction is what the
project's own rule demands: *the experiment that proves it must itself be
verified.* A probe is code, and it fails the way other code fails.

### F6 — A refused arm strands the heartbeat it stamped

The arm stamps its lease **before** opening the stream — deliberately, since
0027 deviation (b): the watcher's first action is to test for that file, so the
client's mark must precede the watcher. The refusal path then returns without
ever creating the `WatchArmed` whose teardown would remove it:

```dart
if (early == boundedWatchLockedExit) {
  releaseSlot();
  await handle.cancel();
  onDiagnostic?.call('another live watcher already holds $repoPath — polling here');
  _record(repoPath, WatchTransition.armFailed, 'held by another watcher', 0);
  return const WatchUnavailable(WatchUnavailableReason.heldByAnother);
}
```

`releaseLease()` lives in the `WatchArmed` teardown closure (0041 phase 2) and
is therefore unreachable from here. Every refused arm leaves one
`mg-watch.<token>.hb` with no pid file beside it.

Observed on the host: **four such orphans** for the reporting repository, from
the four refusals preceding the arm that eventually won:

```text
21:31:37  mg-watch.<tokenA>.hb      (refused — no pid file)
21:32:59  mg-watch.<tokenB>.hb      (refused — no pid file)
21:37:18  mg-watch.<tokenC>.hb      (refused — no pid file)
21:37:58  mg-watch.<tokenD>.hb      (refused — no pid file)
21:40:59  mg-watch.<tokenE>.pid + .lock   (won; live)
```

This is litter, not a leak: `watcherSweepScript`'s second loop reclaims a
heartbeat with no pid file once it is stale, and 0027 designed that loop for
exactly this shape. It is recorded because it is a visible symptom that helps
identify the condition on a host, and because a fix for the collision removes
most of its supply.

### F7 — What a spurious refusal costs

`heldByAnother` is deliberately excluded from the slot-release wake — the
`slotSub` listener fires only for `WatchUnavailableReason.ceiling` — so a
repository refused this way waits for `recoveryInterval`, which is **three
minutes**, before it tries again. Until then it polls.

MADR 0040 F5 measured that fallback at roughly **48 git processes per minute per
repository**. A single spurious refusal therefore costs on the order of 150 host
processes and three minutes of degraded freshness, for a repository that was
perfectly watchable and whose only obstacle was itself. The reporting session
took four of them before one arm won.

The design intent is intact: a *genuine* cross-session refusal should wait for
the recovery timer, because a slot freeing up in this process says nothing about
a lock held in another. It is only the self-collision that makes the wait
gratuitous.

### F8 — The host was healthy when measured, which is consistent with a transient collision

Taken after the report:

```text
lock dir token:      <tokenE>          (matches the one live watcher)
live watchers:       1                 (host-wide)
SSH sessions:        one triple-client group, one tab
registry:            1 live token pair + 4 stale heartbeats (F6)
```

Exactly one watcher, holding a lock it owns, heartbeating on schedule. The
collision had resolved by the time it was inspected — as it must, since the
losing arm's fifth attempt succeeded. This is the signature of a race, not of a
stuck state, and it is why the condition is easy to miss: it repairs itself and
leaves only litter and a polling repository behind.

### F9 — What is not established

**What created the second subscription.** F1 proves two instances coexisted; it
does not identify what produced the second one in a session with a single remote
tab. Candidates, none confirmed:

* a transient second listener on `repoWatchProvider(repoPath)` from a view that
  mounted while another was still disposing, in a container where the first
  instance had not yet lost its last listener (so no `stopped`);
* two distinct `repoPath` strings that differ textually but resolve to one git
  dir — ruled *unlikely* because both records landed in one log, which is keyed
  by the raw string, but not ruled out for the lock itself, which is keyed by
  git dir;
* something in the connect/reconnect path constructing a watch outside the
  provider's lifecycle.

The decision below does not depend on resolving this, for the same reason MADR
0042's F5 did not: every candidate is a way of asking the client to watch one
repository twice, and the fix is to make that request impossible to honour
rather than to enumerate its origins. Naming the trigger would let it be fixed
*additionally*, not *instead*.

## Decision Drivers

* One session must never hold two watchers on one repository — that is not a
  policy preference, it is the invariant MADR 0041 F12 named and only
  half-enforced.
* The host-side lock must be a **backstop against other processes**, not the
  mechanism that discovers this process's own mistakes.
* A refusal must mean something a user would recognise as real. `heldByAnother`
  should be reachable only when another *session* genuinely holds the
  repository.
* Teardown must be complete in the sense that matters to the next arm: the host
  resources are released, not merely the local handles.
* Whatever is built has to hold across `watchLifecycle` instances, since
  `startChain` already covers everything inside one and this defect lives
  precisely in the gap between them.
* The cost of being wrong is asymmetric: a spurious refusal costs three minutes
  of polling at ~48 processes/minute, while a slightly delayed arm costs
  milliseconds.

## Considered Options

* **A — Do nothing; the lock already prevents two live watchers.**
* **B — Retry a `heldByAnother` refusal after a short delay.**
* **C — Serialise arms per repository path inside `RemoteWatchService`.**
* **D — Make teardown await the host-side lock release.**
* **E — Teach the arm to recognise its own session's token and steal from it.**
* **F — Deduplicate at the provider layer instead.**

## Decision Outcome

Chosen option: **C and D together, with C read as *sharing* rather than merely
queueing** — one watcher per repository path per service, additional subscribers
attached to it rather than arming their own; plus a teardown that does not report
completion until the host-side lock it held is actually gone.

**A correction, made while planning this work and recorded here rather than
buried.** An earlier draft of this outcome read C as "serialise arms per path:
make a new arm wait for the previous one's teardown." That closes F3's route and
does nothing whatever for the incident actually reported. F1 establishes that the
first watcher was **still running** — not tearing down — when the second was
refused. There is no teardown in flight for a queue to wait on. A gate keyed on
teardowns would have shipped, passed its tests, and left the reported symptom
exactly as it is.

The distinction is between two collisions that look identical from the host:

| | First watcher | What the second must do |
| --- | --- | --- |
| **Coexistence** (F1, F2 — the reported incident) | alive, staying alive | attach to it; never arm |
| **Teardown seam** (F3) | dying, lock not yet released | wait for the release, then arm |

So the fix has two halves, and each covers a case the other cannot:

* **Sharing** covers coexistence. A second `watch()` for a path this service is
  already watching returns the *same* underlying watcher's events. No second
  arm, no second token, no second slot, no refusal.
* **The teardown gate + awaited lock release** covers the seam. When the last
  subscriber leaves and a new one arrives before teardown has finished, the new
  arm waits for the lock to be genuinely released rather than racing it (F4's
  sub-second window).

Together: **this process arms at most one watcher per repository path, and never
begins an arm while a previous arm for that path still holds its lock.** *(As
shipped, this held for every interleaving the tests exercised and not for one
they did not — see amendment 0043.1.)*

Sketch, to be settled in the plan:

1. `RemoteWatchService` holds one shared watch per `repoPath`, created on the
   first subscriber and torn down when the last one leaves. Dart's
   `StreamController.broadcast` already provides exactly that refcount through
   its `onListen`/`onCancel`, so this is a small amount of new machinery rather
   than a new lifecycle.
2. A late subscriber receives the current `RepoWatchEvent` immediately, so its
   mode indicator is correct without waiting for the next tick — the shared
   watch retains the last event for replay.
3. ~~The teardown future is retained; a `watch()` arriving for that path while it
   is pending awaits it before creating a new lifecycle.~~ Bounded, so a teardown
   that never completes degrades to today's behaviour rather than hanging a
   repository forever — a timeout yields the current race, not a worse state.
   **Superseded by amendment 0043.1:** a retained teardown plus a deferred build
   could interleave to orphan a watcher. Attach and detach are serialized onto
   one chain instead; the bound is kept.
4. The `WatchArmed` teardown releases the lock explicitly and **awaited**,
   guarded by token ownership exactly as the host-side `cleanup()` trap is:
   remove the lock directory only while it still names this token. The client
   already knows the git dir and its own token, and already issues a comparable
   removal for the heartbeat.
5. The heartbeat removal moves out of the `WatchArmed` closure so the refusal
   path can use it too, closing F6.

**Deliberately not process-wide.** Sharing is scoped to one service instance,
which is one connection, which is one tab. Two tabs on one repository still
collide on the host lock, and that is correct — they are different sessions with
different connections, and MADR 0041 F12 built the lock for exactly that. It
also means a service rebuild (a new executor after a reconnect) starts with an
empty map, so sharing does not span reconnects; the teardown gate and the lock
cover that seam.

The host-side lock stays exactly as it is. Its job becomes what it was designed
for: refusing a genuinely foreign session.

### Why not the others

**A — do nothing.** The lock does prevent two live watchers, so nothing is
*corrupt*. What it does not prevent is the cost: F7's three minutes of polling
per refusal, four times in the reporting window, and a `heldByAnother` diagnostic
that tells a maintainer a competing session exists when none does. *Bad, because
it leaves a correct-looking message that is actively misleading during
diagnosis* — this investigation began by trusting it.

**B — retry after a delay.** Cheap, and it would have masked the report. It
treats a race whose window is known and short (F4) with a guessed constant, and
it cannot distinguish a self-collision worth retrying immediately from a genuine
foreign holder worth waiting three minutes for — so it either retries into real
contention or under-waits for it. *Bad: a timing guess in place of the ordering
guarantee the situation actually admits.* This is the retry-as-bandaid the
project's working style names directly.

**E — recognise our own token and steal.** Appealing, and strictly more
information than B: the refusing script already reads the incumbent token
(`o=$(cat "$L/token")`) and could report it, letting the client compare against
the token it just abandoned and steal on a match. It fixes the symptom precisely
and leaves the cause — two arms in flight for one repository — untouched, so the
duplicate slot reservation, duplicate heartbeat, and duplicate stream open all
still happen and merely stop being visible. *Neutral: correct as far as it goes,
and it goes to the wrong place.* Worth revisiting only as a diagnostic (reporting
the incumbent token would have shortened this investigation considerably).

**F — deduplicate at the provider layer.** `repoWatchProvider` is already a
family keyed by path, so Riverpod dedupes within one container; the failure is
across containers and across generations, which the provider layer cannot see.
It would also leave `RemoteWatchService` — a public seam with three
implementations behind it — still willing to arm one repository twice for any
future caller. *Bad, because it puts the guard above the invariant instead of
at it.*

### Consequences

* Good, because `heldByAnother` becomes trustworthy: after this it can only mean
  another session, which is what it says and what a maintainer will act on.
* Good, because the duplicate reservation disappears with the duplicate arm —
  today a self-collision transiently consumes two of the derived ceiling's slots
  (F2 measured `slots held: 2`), which on a degraded single-client session,
  where the ceiling floors at 1, is the difference between watching a
  repository and not.
* Good, because F6's litter loses most of its supply, and the refusal path gains
  the cleanup it should always have had.
* Good, because the guarantee is stated in terms of the resource that matters —
  the lock — rather than in terms of elapsed time, so it does not decay when the
  host is slow or the link is long.
* Bad, because teardown gains a round trip it did not have. Teardown is not on a
  hot path, but it is now on the path of every tab close and repo switch, and a
  disconnecting executor must not make it hang — the removal has to be bounded
  and swallow its failures, exactly as `releaseLease()` does.
* Bad, because a per-path chain is process-global mutable state, which is the
  category MADR 0039 spent ten phases partitioning. It must be keyed by
  `(host, gitDir)` and not merely by path, and it must not become a second
  place where "one session at a time" is assumed.
* Neutral, because nothing a user sees changes when there is no collision, and
  the cross-session behaviour the lock was built for is untouched.

### Confirmation

Each claim has a check that can fail, and two already have:

* **F1's inference** — that `armed` adjacent to `armFailed` implies coexistence
  — is confirmed by F2's reproduction, which produces exactly that record pair
  from two concurrent subscriptions. It must keep producing it: the
  reproduction becomes a regression test that fails once the gate lands, and is
  then inverted to assert a single arm.
* **F2's gap** — after the fix, two concurrent `watch()` calls for one path must
  yield **one** armed watcher, one token, one slot, and the second subscription
  must either share or wait, never arm in parallel.
* **F3's rebuild ordering** — the same overlap driven through an actual provider
  invalidation must also yield one live watcher on the host, not a refusal.
* **F4's window** — with the fix, an arm issued immediately after a teardown for
  the same path must acquire the lock rather than be refused. Today, against a
  real host, the pre-fix code loses this race intermittently; the test must be
  run against the current tree first and seen to fail.
* **F6** — a refused arm must leave no `mg-watch.<token>.hb` behind. Provable by
  census on a host after forcing a refusal from a genuinely foreign session.
* **Cross-session behaviour is unchanged** — a second *process* must still be
  refused with `heldByAnother` and must still wait for the recovery timer. This
  is the check that the fix has not quietly disabled the feature it is
  protecting, and it needs two app instances or a standalone script holding the
  lock.

The honest limit: **the trigger in the reported session is not identified**
(F9), so no check here can confirm that this specific incident cannot recur by
some other route. What the checks establish is that the *class* is closed — one
session cannot arm one repository twice — which is strictly stronger than
closing the one path that happened to be taken.

## Amendments

### 0043.1 — sharing could orphan a watcher; attach and detach are now serialized (2026-09-10)

Found on a live host during MADR 0044's phase 4 verification, and fixed under that
plan (`0044-PLAN-the-watcher-follows-the-active-tab.md`, deviation (c)), because
that is the plan whose verification found it.

**What was observed.** A remote tab's watcher kept its host lock and kept renewing
its lease for more than thirty minutes after its tab went to the background, while
another remote tab was active. The app had exactly one content window, so no
pop-out subscription held it. A scratch reproduction of the tab host's in-place
container swap showed widget unmount disposing the provider correctly in both
directions, so disposal was not what failed.

**The mechanism.** Two pieces of `_SharedWatch`
(`lib/core/git/remote_watch_service.dart`, as shipped in `edc06b3` and
`2cb8f9b`):

* `_detach`, when a subscriber leaves while a build is still deferred — so there
  is no `_source` yet — set `_teardown = null`, discarding the teardown that was
  still in flight.
* `_attach`'s deferred callback built `if (_out.hasListener)`, without checking
  whether a newer build had already run, and `_build()` overwrote `_source`.

So **leave → arrive → leave → arrive inside one teardown** built twice and kept a
handle to only the second watcher. The first was reachable from nothing: no
subscriber, no teardown, still holding its slot, its lock and its lease.

**Reproduced against the committed tree**, with the real `RemoteWatchService` and a
400 ms teardown, and a control run through the same harness:

```text
RACE    leave, arrive, leave, arrive inside one teardown; then all leave:  live=1  liveWatchers=1
CONTROL one clean leave and arrive; then all leave:                        live=0  liveWatchers=0
```

None of the ten tests in `watch_shared_path_test.dart` has a subscriber leave while
a build is deferred, which is why this record's sabotage round had nothing to kill.

**The trigger is inferred, not observed.** A full reconnect calls
`_invalidateRepoState()`, which invalidates the whole `repoWatchProvider` family,
while the dying watcher's `releaseHostClaims()` runs against a transport that is
redialing, on a 15-second timeout — the widest window this race could ask for. The
orphan on the host was born three seconds after its tab's connection was
established. No sampler was running at that moment, so the exact sequence was not
captured.

**What it contradicts.** The guarantee in the Decision Outcome above, and sketch
step 3, which were annotated rather than rewritten.

**The decision, changed.** Every `onListen` and every `onCancel` on the shared
controller enqueues one reconcile step onto a single chain for that path. Each step
compares what is wanted (`_out.hasListener`) with what exists (`_source != null`)
*at the moment it runs*, and either builds, or tears down and awaits the teardown
before the next step may run. There is no deferred callback and no separately held
teardown for an interleaving to clobber: whatever order subscribers arrive and
leave in, the steps run one at a time against the state as it then is. It is
`watchLifecycle`'s `startChain` (MADR 0026 H1) applied one level up — the idea this
record's More Information already pointed at. **The bound is kept:** an awaited
teardown is capped at `sharedTeardownGrace`, so a teardown that never completes
still degrades to the old race rather than wedging the path's chain.

The rejected alternative was keeping both fields and adding the two missing
guards — smaller, and it closes this interleaving while leaving the class open to
the next piece of state added to `_SharedWatch`. The maintainer chose
serialization.

**What the defect cost while it stood.** An orphan holds its repository's lock and
lease until its tab's SSH connection dies. It occupies a host-wide watcher slot
(`_liveByHost` is static), pressing other repositories toward `ceiling` polling.
And returning to its repository gets that repository's own new arm refused as
`heldByAnother`, naming its own orphan, and polling at ~48 git processes a minute —
this record's reported symptom, arriving by a different route.

### 0043.2 — the serialized chain is superseded by MADR 0045 (2026-09-10)

Amendment 0043.1's decision was implemented and then withdrawn before it was
committed. As specified, each chain step compared "someone is subscribed" with "a
watcher exists" when it ran, so a provider rebuild — which cancels the old
subscription and subscribes the new one in the same flush — looked like no change at
all, and **new watch parameters were dropped**. An existing test caught it
(`Expected: ['arm', 'teardown', 'arm']`, `Actual: ['arm']`). A scratch rebuild with a
bounded surface armed `[recursive]` against the chain, and `[recursive, bounded]`
against a clean worktree of the unmodified code.

The maintainer then directed an architectural review rather than another patch. It is
recorded as
[0045-MADR-one-owner-per-watcher-concern.md](0045-MADR-one-owner-per-watcher-concern.md)
(proposed). Its central finding bears directly on this record: **sharing solved an
exclusion problem.** Riverpod already gives one provider instance per repository per
container, and the watch services have exactly two production callers, both inside
`repoWatchProvider`. What production needed was the teardown seam this record's F3 and
F4 describe, expressed as exclusion, not as a layer that owns watcher lifetime.

This record's guarantees stand: one watcher per repository per session, and no arm
while a predecessor holds the lock. Its mechanism — sketch items 1–3 and amendment
0043.1 — is superseded by MADR 0045, once that record is accepted.

## More Information

* [0041-MADR-the-watcher-the-client-cannot-kill.md](0041-MADR-the-watcher-the-client-cannot-kill.md)
  — F11 (stdin-EOF teardown) and F12 (the host lock) are the two findings this
  record continues. F12 anticipated the cross-session collision and built for
  it; this record is the same-session case it did not consider.
* [0041-PLAN-the-watcher-the-client-cannot-kill.md](0041-PLAN-the-watcher-the-client-cannot-kill.md)
  phase 3 — the `mkdir` lock, its steal rule, and `boundedWatchLockedExit`.
* MADR 0026 H1 and `watchLifecycle`'s `startChain` — arms serialised *within* an
  instance. This record is the gap between instances, and the chosen fix is the
  same idea one level up.
* MADR 0039 — the process-global state audit whose conclusions constrain how the
  per-path chain in (1) may be keyed.
* MADR 0040 F5 — the ~48 git processes per minute per repository that make a
  spurious three-minute polling window expensive (F7).
* `watch_diagnostics.dart` — `WatchDiagnostics` keyed by bare `repoPath`, the
  conflation that made F1 legible. Worth revisiting: it is a liability for
  attributing behaviour and was an asset exactly once, here.
* Measurements were taken on the reporting host on 2026-09-09 between 21:31 and
  21:56 host time, against the build from `890bca1`. All probe artefacts were
  removed and the host verified clean afterwards.
