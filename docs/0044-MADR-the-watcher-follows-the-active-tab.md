---
status: "accepted"
date: 2026-09-10
decision-makers: [Maintainer]
consulted: []
informed: [Magic Git contributors]
verified: 2026-09-10
---

# The watcher follows the active tab, and the reason to change that is not the one it looks like: the switch costs 400 ms, 250 of which is a timeout we chose

## Context and Problem Statement

The maintainer asked:

> instead of the single active follow the active tab model, why can't we use
> stateful threads and ensure the watcher is concurrently watching all open repo
> remote tabs?

Three claims are packed into that, and they need separating before any of them
can be answered:

1. that the app follows the active tab — **true**, proven at runtime below;
2. that threads are what stand in the way — **not true**, and the reason is
   structural rather than a matter of degree;
3. that watching every open remote tab concurrently would be better — **it
   depends entirely on what "watching" is taken to mean**, and the two readings
   have opposite cost profiles.

This record establishes what the app actually does, measures what it costs, and
finds that the strongest argument in the neighbourhood is one the question did
not raise: **63 % of what a tab switch costs is a fixed timeout this project
introduced yesterday, not anything to do with watchers or tabs.**

### How this was measured

Two remote tabs were opened by the maintainer against the reporting host while
the measurements below were taken. Every number in the Findings is from that
session on 2026-09-10, or from the code as it stands, and each is labelled.

**The running build is `890bca1` (tag `v1.6.3`)** — read from the installed
bundle's `CFBundleShortVersionString` (`1.6.3.0`), which the version stamp
derives from `git describe`. It contains MADR 0041 and 0042 in full and **none
of MADR 0043**. That is not a problem for this record: 0043 changed how a
watcher is shared and torn down, not whose tab owns it, and the tab model is
what is under examination.

## Findings

### F1 — One watcher, two tabs. Measured.

With two remote tabs connected:

```text
sshd notty sessions:      6  (two triple-client groups, 00:38 and 00:23 elapsed)
distinct live watchers:   1
lock held:                <repo-A>  token=<tokenA>
inotifywait watches:      438
```

Two tabs, two complete SSH connections, **one watcher**. The second tab is
connected and watching nothing.

### F2 — The code names this, and the mechanism is a widget key

`lib/features/tabs/tabs_host.dart`:

```dart
Expanded(
  child: KeyedSubtree(
    key: ValueKey(controller.activeId),
    child: const AppShell(),
  ),
),
```

Exactly one `AppShell` exists. Changing the active tab changes the key, which
unmounts the old shell and mounts a new one. The comment above it uses the term
directly — *"single-active-mount"* — and states the consequence: *"background
tabs' autoDispose fetches quiesce; their sockets stay alive."*

`repoWatchProvider` is a `StreamProvider.autoDispose.family`
(`app_providers.dart:3726`). No mounted shell means no listener means the
provider disposes means the watcher is torn down. F1 is that sentence, observed.

### F3 — A background tab costs almost nothing. Measured, sustained.

Sampled at 2 Hz across the observation window, with both tabs connected:

```text
git processes running:     0   (sustained, every sample)
inotifywait processes:     1
```

Not one git process. The background tab is not polling either — polling belongs
to `watchLifecycle`, and there is no lifecycle, because the provider is gone. A
background tab's entire cost is **three idle sshd sessions**.

This matters more than it first appears. The proposal's implicit premise is that
the current model is wasteful. It is the opposite: at rest it is very nearly
free, and any move toward concurrent watching is a move from ~zero cost to some
cost. The question is what is bought.

### F4 — What survives a tab switch, and what does not

| | Survives | Mechanism |
| --- | --- | --- |
| the SSH connection | **yes** | `connectionProvider` is a plain `NotifierProvider`, not autoDispose |
| content caches (diffs, blobs, blame, file logs) | **yes** | ten `KeepAliveLru` instances, hash-keyed — a given commit's diff cannot change |
| the watcher | no | `repoWatchProvider` is autoDispose |
| status, snapshot, refs | no | `statusProvider`, `repoSnapshotProvider`, `refsProvider` are all `FutureProvider.autoDispose.family` |

The split is principled: **immutable-by-hash state is cached across tabs;
mutable state is not.** That is what makes the next finding decisive.

### F5 — Keeping watchers alive, alone, would be strictly worse

This is the finding that answers the question as literally asked.

A watcher exists to say *"the mutable state changed."* But F4 establishes that
the mutable providers are disposed the moment a tab goes to the background —
there is no cached status, no cached refs, nothing that a change notification
could invalidate. On return, they refetch regardless of whether anything was
watching.

So a background watcher's ticks arrive and land on nothing. Every consumer that
reacts to a tick is widget-scoped:

| Consumer | Kind | Scope |
| --- | --- | --- |
| `repo_status_view.dart:1581` | `ref.listen` | widget |
| `repo_status_view.dart:1635` | `ref.watch` | widget |
| `history_view.dart:1344` | `ref.listen` | widget |
| `dashboard_sheet.dart:627` | `ref.watch` | widget |
| `window_manager_bridge.dart:354` | `container.listen` | **not** a widget — but pop-out windows only |

And the ticks are not free even with nobody listening. `_withoutIgnoredPaths`
runs on every scoped event before any consumer sees it, and calls
`oracle.visible(repoPath, event.paths)` — which batches unknown paths into a
host round trip on a cache miss. A background repository with churn (a build, a
fetch, a colleague's push) would pay round trips to filter events that are then
discarded.

**Net: inotify descriptors held, events across the wire, ignore-oracle round
trips — and on return you refetch anyway.** Cost with no benefit. This version
of the proposal should not be built.

### F6 — The app already implements the proposed pattern, one level down

Within a tab, pages behave exactly the way the question wants tabs to behave.
`IndexedStack` keeps every visited page mounted, and `_onWatchTick` gates the
*work* rather than the *subscription* (`repo_status_view.dart`):

```dart
// While this page is hidden (another tab is up) don't fire a `git status`
// round-trip on every tick … Keep the subscription (so the watcher stays
// alive) but skip the refetch; didUpdateWidget re-syncs once when the page
// becomes visible again.
if (!widget.isActive) { … return; }
```

Stay subscribed, skip the work, re-sync on return. The pattern is established,
in-tree, and proven — the only reason it does not extend across tabs is that
tabs unmount entirely, so there is no subscriber left to keep.

Note also what is *not* gated: a tick that moved git's own state calls
`_invalidateMutationFamilies` regardless of page visibility, because sibling
panels stay mounted. So the app already distinguishes "hidden but alive" from
"gone", and treats them differently — which is precisely the distinction a
cross-tab version would need.

### F7 — The switch costs ~400 ms, and 250 ms of it is a timeout we chose

Measured on the reporting host, 2026-09-10.

Round trip on an **already-established** channel — no process spawn, the closest
analogue to what dartssh2 pays issuing a command on a live client:

```text
n=15   median 49.4 ms   min 47.5 ms   (one 501 ms outlier)
```

Remote-side execution, measured inside a single session so no transport is
included:

```text
tool probe   2 ms
lease stamp  2 ms
```

So the host does essentially no work; an arm is transport plus waiting. An arm
makes three sequential round trips — the tool probe, the awaited lease stamp,
and the stream open — and then waits a **fixed 250 ms** on the early-exit read
that MADR 0042 widened to every arm:

```text
3 × 49 ms   = 148 ms
+ early-exit  250 ms
------------------
              ~400 ms
```

**The single largest component of arming a watcher is a timeout, and it is
larger than everything else combined.** For a healthy arm the exit code never
completes, so the full 250 ms is always paid, on every tab switch, for every
repository.

That reframes the question. If the complaint behind it is that switching tabs
feels stale or slow, the cheapest available fix is not to keep six watchers
alive — it is to stop waiting a quarter of a second for a status that a healthy
arm will never produce.

### F8 — Host capacity is not the constraint, and is not close

Measured 2026-09-10:

```text
max_user_watches      524288
max_user_instances      1024
instances in use            8
```

Per-repository watch cost across the working directory, after the `@`-path
exclusions MADR 0042 phase 5 added:

| Repository | dirs | watched |
| --- | --- | --- |
| `<repo-A>` | 701 | **437** |
| `<repo-B>` | 336 | 69 |
| `<repo-C>` | 281 | 96 |
| `<repo-D>` | 276 | 26 |
| `<repo-E>` | 263 | 55 |
| … 9 more | | |
| **14 repositories, all watched at once** | 2 476 | **857** |

857 of 524 288 is **0.16 %**. Watching every repository on the host
simultaneously would consume a sixth of one percent of its inotify budget, and
14 of 1 024 instances.

Two things follow. First, **inotify is not why the app watches one repository at
a time** — nothing about the host forces this. Second, the `@`-exclusions are
worth more than their record claimed: measured across the fleet they cut 2 476
descriptors to 857, a **65 % reduction**, rather than the ~38 % measured on the
single repository 0042 F9 used.

### F9 — What would actually bind is a ceiling derived from one session's budget

`maxConcurrentWatchers` is `max(1, maxConcurrentStreams - reservedStreams)` =
`max(1, 8 - 2)` = **6**, and `_liveByHost` keys it by **host**, statically
(MADR 0041 F5, reaffirmed by 0043). `TabsController.maxTabs` is **8**.

Today the cap is nearly unreachable, because only one tab watches at a time —
F1 measured one watcher against a ceiling of six. Under concurrent watching it
becomes the everyday constraint: 8 tabs on one host would give 6 watchers and 2
repositories polling.

And the derivation would be wrong in a way it currently is not. The cap is
computed from **one** session's channel budget (`maxConcurrentStreams`, 8 per
connection) and then applied across **all** sessions on that host. F1 shows each
tab dials its own triple-client, so eight tabs hold eight independent 8-channel
budgets — 64 channels — while sharing a cap derived from one of them. That is
conservative in the right direction today and simply inaccurate under concurrent
watching; it would need revisiting as part of any such change.

### F10 — "Stateful threads" is a category error, and a costly one

Dart has no threads. It has isolates, which do not share memory: every object
crossing between them must be copied or sent as a message.

The watcher is **I/O-bound, not CPU-bound**. F7 measures 2 ms of remote work per
command; the rest is waiting on a socket, which an event loop does without
blocking. There is nothing for a second thread of execution to do. Moving a
watcher into an isolate would require the executor, the SSH client, the
connection state and every provider it touches to cross an isolate boundary —
substantial cost, considerable complexity, and no benefit, because concurrency
was never the limit.

**The app is already capable of watching every open tab concurrently.** Six
simultaneous watchers is what the ceiling permits *now*. What prevents it is not
parallelism but **lifetime**: a watcher lives exactly as long as a widget
subscribes to it. That is a lifetime question, and it has a lifetime answer —
hold a subscription somewhere that outlives the widget tree, which
`window_manager_bridge` already demonstrates with
`container.listen(repoWatchProvider(repoPath), …)` for pop-out windows.

### F11 — An observation with a loose end

The registry carried a stranded heartbeat with no pid file beside it:

```text
<repo-A>/.git/mg-watch.<tokenA>.pid      (live watcher)
<repo-A>/.git/mg-watch.<tokenA>.hb       (live watcher)
<repo-A>/.git/mg-watch.<tokenB>.hb       (no pid — stranded)
```

An arm stamps its lease before opening the stream (0027 deviation (b)), so a
stamp with no pid is an arm that never became a watcher. The VPN dropped and was
restored during this session, which would interrupt an arm in exactly that way.

**Attribution is genuinely ambiguous and should not be guessed at.** The running
build predates MADR 0043, whose phase 3 gave the refusal paths their cleanup —
so on this build no refused arm cleans up, and this is expected. But 0043's
cleanup covers `heldByAnother` and `noWatchedPaths` only; an arm that *throws*
still goes to the catch-all, which releases the slot and rethrows without
touching the lease. If that is the path taken here, 0043 would not have prevented
it either. Worth a look when 0043 is next built and running; not worth a
conclusion now.

## Decision Drivers

* A change must buy something the current model does not already provide. F3
  measures the current cost at rest as approximately zero, so anything proposed
  is a cost increase and must justify itself on benefit alone.
* The user-visible complaint, if there is one, is presumably staleness or delay
  on switching tabs. Whatever is built should be aimed at *that*, measured.
* Work done for a repository nobody is looking at should be work someone will
  actually use — the page-level gate (F6) is the project's existing expression
  of that principle.
* The host is not a constraint (F8) and concurrency is not a constraint (F10),
  so neither should be used to justify or reject a design.
* Anything that keeps state alive across tabs must not re-create the
  process-global coupling MADR 0039 spent ten phases removing.

## Considered Options

* **A — Leave it as it is.**
* **B — Keep watchers alive for background tabs.**
* **C — Keep watchers *and* the mutable provider graph alive and refreshing.**
* **D — Keep watchers alive to surface "this repository moved" on the tab strip.**
* **E — Cut the cost of the switch instead.**

## Decision Outcome

Recommended: **E, and then D only if the goal is genuinely "know what changed
while I was away."** **B should not be built. C is a separate, much larger
decision that this record does not make.**

**E — cut the cost of the switch.** F7 measures the switch at ~400 ms, of which
250 ms is the early-exit read waiting for an exit status that a healthy arm never
produces. That wait exists to catch a script-level refusal (no watchable paths;
another session holding the lock), and it was widened from bounded arms to every
arm by MADR 0042's plan, deviation (b) — which accepted the cost explicitly and
did not measure it. It can be raced instead of waited on, and it improves every arm —
including the first one after connect, which no amount of background watching
would help. ~~The first byte of stdout proves the watcher armed, and a refusal
closes the stream immediately, so whichever arrives first settles the question
with no fixed delay.~~ **See Amendment 0044.1: stdout is the wrong signal, and
the mechanism is an explicit readiness marker on stderr.**

**D — a "changed while you were away" indicator**, if that is the actual goal.
This is the one reading of the question where an unconsumed tick has value:
nothing else in the app can tell you a background repository moved, and a dot on
the tab strip is a real capability rather than an optimisation. It needs a
non-widget subscriber per tab (the `window_manager_bridge` pattern), a place to
record "something moved", and — importantly — **not** a refetch, so the cost
stays bounded to the ignore-oracle filtering F5 describes. It should be judged as
a feature, with its own record, not smuggled in as a performance change.

### Why not the others

**A — leave it as it is.** Defensible, and the honest default: F3 shows the
current model is nearly free, and F7's 400 ms is not obviously a problem anyone
has complained about. *Neutral.* It is rejected only because E is cheap enough
that leaving a 250 ms fixed wait in place is hard to justify once measured.

**B — keep watchers alive.** F5 is the argument: the mutable providers are
disposed anyway, so the ticks land on nothing and the data refetches on return
regardless, while the host holds descriptors, the wire carries events, and the
ignore oracle spends round trips filtering them. *Bad — a cost increase with no
corresponding benefit.* This is the version the question asks for most directly,
and it is the one that should not be built.

**C — keep watchers and the provider graph alive.** This is what would make
switching genuinely instant, and it is coherent. It also multiplies, by the
number of open tabs, precisely the work the page-level gate exists to avoid
(F6), and it requires keeping mutable repo state alive across tabs — the
opposite of the principled split F4 documents. *Bad as an incremental change;
legitimate as a deliberate architecture decision with its own record, its own
cost measurements, and a hard look at F9's ceiling.*

**Threads / isolates.** *Bad, and not applicable* — F10. Recorded so the idea is
not revisited without the reason it was set aside.

### Consequences

* Good, because E is measured rather than assumed: the 250 ms is a number taken
  from this host today, and the improvement can be verified the same way.
* Good, because E helps every arm, not only tab switches — the first arm after
  connect, every restart, every recovery from polling.
* Good, because declining B on measured grounds means the question is settled
  with evidence rather than taste, and F5 explains *why* in terms that will still
  be true later.
* Bad, because E touches the early-exit read, which is load-bearing for two
  refusal paths — racing it against first-stdout must not reintroduce the three
  doomed restarts of 0022 M6, and that needs an executing test rather than an
  argument.
* Bad, because this record leaves the ceiling's derivation (F9) known to be
  inaccurate-under-concurrency and does not fix it. That debt is only payable if
  C or D is ever taken up, but it is now written down.
* Neutral, because nothing here changes what the user sees at rest; F3's
  measurements should be unchanged afterwards.

### Confirmation

* **F1/F2/F3** are directly repeatable: open N remote tabs and count distinct
  watcher tokens on the host. It must be 1 while single-active-mount stands, and
  N afterwards if D or C is ever built.
* **F7's 250 ms** — after E, an arm must complete in roughly three round trips
  (~150 ms on this host) rather than ~400 ms. Measurable by timing from `watch()`
  to the `armed` transition; the diagnostics already record it.
* **E must not break the refusals it replaces** — the executing tests in
  `watch_lease_teardown_exec_test.dart` already cover a lock refusal and a
  no-watchable-paths refusal against real processes. Both must still degrade to
  polling immediately rather than spending the restart budget. If a race cannot
  be made to fail on demand for the refusal case, say so and describe what the
  test actually establishes.
* **F8's headroom** should be re-measured before any concurrent-watching work,
  since it is the premise that the host can absorb it.

The limits worth naming: **the tab-switch transition itself was not observed** —
the watcher moving from one repository to another as the active tab changes.
Everything about the switch is derived from the code path plus F7's component
timings. And **F11's stranded lease is unattributed**, deliberately.

## Amendments

### 0044.1 — stdout is silent until the first filesystem event (2026-09-10)

Raised while writing `0044-PLAN-the-watcher-follows-the-active-tab.md`, before
any code was touched. **Option E's stated mechanism was wrong**, and the plan
would have been built on it.

The claim was that "the first byte of stdout proves the watcher armed". It does
not. `inotifywait` is armed with `-m … --format %w%f`, and `fswatch` with `-0`:
both write **only event records** to stdout, and a repository at rest produces
none. A healthy watcher can be silent for minutes, so racing the early-exit read
against first-stdout would replace a fixed 250 ms wait with an unbounded one —
strictly worse, and it would have passed a test that armed a fake handle
emitting a fake event.

What is true, and is what the plan builds on:

* The two refusals exit **before** the watcher process is started —
  `boundedWatchNoPathsExit` from the existence filter, `boundedWatchLockedExit`
  from `_lockPrelude` — and both run before `_recordPid` and before the lease
  loop's `{ $inner; } & w=$!`. So a signal emitted at that point cannot be
  produced by either refusal, which makes the race well-ordered rather than a
  matter of timing.
* **stderr is unbuffered** and is already carried on the same channel, already
  parsed line-by-line, and already has a precedent for a script-authored
  message the client matches: `_lockPrelude` emits `mg-watch: lock held by $o`
  there, and `_lockHeldBy` reads it.
* `inotifywait` already prints `Watches established.` to stderr, and
  `_isWatcherStartupNoise` already recognises it — evidence the signal arrives,
  but tool-specific: `fswatch` prints nothing equivalent, so it cannot be the
  mechanism for both backends.

The correction changes the size of the win, and F7's arithmetic should be read
with this in place: the fixed 250 ms becomes roughly one round trip (~50 ms on
the reporting host), so an arm goes from ~400 ms to ~200 ms — a **50 %**
reduction rather than the 63 % the un-raced number implied. The ceiling that
remains is a backstop against a host that emits neither signal, not a cost every
arm pays.

One further consequence the original text did not anticipate: because the
readiness listener must be attached to stderr *before* the race, the refusal
path no longer needs `_incumbentToken`'s second `handle.stderr.join()` with its
own 250 ms timeout. The incumbent's token is already in hand when the refusal is
detected, so **the refusal path gets faster too**, and one timeout is deleted
rather than added.

### 0044.2 — the arm protocol had eleven test doubles and no single place to change (2026-09-10)

Found during phase 2, when the client started settling an arm on the readiness
marker. Seven test files went red at once, and the reason was not the change: it
was that **eleven hand-rolled doubles stand in for the SSH channel a watcher arm
opens**, across ten files, each re-implementing `CommandStreamHandle` from
scratch.

```text
remote_watch_service_test.dart            _SilentStreamHandle, _DrivableStreamHandle
watch_ceiling_derived_test.dart           _Handle
watch_ceiling_per_host_test.dart          _Handle
watch_ceiling_recovery_test.dart          _Handle
watch_diagnostics_both_backends_test.dart _Handle
watch_lease_identity_test.dart            _Handle
watch_transition_wiring_test.dart         _SilentHandle
watch_shared_path_test.dart               _Handle
watch_lease_release_test.dart             _OpenHandle, _ExitedHandle
helpers/mock_executor.dart                MockStreamHandle
```

Five of them — the `_Handle` in `watch_ceiling_derived`, `watch_ceiling_per_host`,
`watch_ceiling_recovery`, `watch_diagnostics_both_backends` and
`watch_lease_identity` — are **byte-identical**: fifteen lines, same SHA. A sixth
(`_SilentHandle`) differs by one boolean field.

**Why this is a finding and not housekeeping.** These doubles encode the arm
protocol — what a live watcher's channel does, and when. When the protocol
changed, nothing failed at the seam; seven files failed in their own terms, and
the plan that made the change undercounted the doubles by seven, because there
was no one place to look. A double that never writes to stderr modelled a host
that cannot exist: the arming script emits `mg-watch: armed` before the watcher
ever looks at the filesystem, so *"silent"* was only ever true of events, never
of the channel. The fakes did not go stale — they were describing something
false, and passing.

They also carry knowledge that has been paid for once and would be paid for
again by anyone writing the twelfth copy. `_ExitedHandle` records that closing an
unsubscribed **single-subscription** controller returns a future that never
completes, so `await handle.cancel()` hangs and the arm never returns — a real
debugging session, preserved in a comment that five other doubles cannot see.

**Decision: consolidate them into one double in `test/helpers/`**, with named
constructors for the three scenarios that actually differ (armed, refused,
silent host) rather than a widening set of flags. The variation is
configuration, not type: what the doubles disagree on is whether the process
exits and with what, whether teardown is observable, and whether the test drives
output — not what a channel *is*.

This is scope this record did not originally carry. It is taken deliberately
rather than deferred, because the alternative was seven more copies of the
one-line change, leaving the next protocol change to rediscover the same
eleven files from its own failures.

## More Information

* `lib/features/tabs/tabs_host.dart` — `KeyedSubtree` on `activeId`; the
  "single-active-mount" comment (F2).
* `lib/features/repository/repo_status_view.dart` — `_onWatchTick` and the
  `widget.isActive` gate; the pattern F6 describes.
* `lib/core/providers/app_providers.dart` — `repoWatchProvider` (autoDispose),
  `connectionProvider` (not), the ten `KeepAliveLru` caches, and
  `_withoutIgnoredPaths` (F4, F5).
* MADR 0042's plan, deviation (b) — where the 250 ms became universal, and where
  the cost was accepted without being measured. F7 is that measurement.
* MADR 0041 F5 and MADR 0043 — why the ceiling is keyed by host, which F9 does
  not disturb but does put a question against.
* MADR 0039 — the process-global state audit whose conclusions constrain how any
  cross-tab state in C or D may be held.
* Measurements taken 2026-09-10 against the reporting host with two remote tabs
  connected, running build `890bca1` (`v1.6.3`). ICMP is blocked on that path, so
  round-trip was measured over an established SSH channel rather than by ping.
