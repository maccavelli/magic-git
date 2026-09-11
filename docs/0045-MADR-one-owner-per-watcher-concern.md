---
status: "accepted"
date: 2026-09-10
decision-makers: [Maintainer]
consulted: []
informed: [Magic Git contributors]
verified: 2026-09-10
---

# One owner per watcher concern: demand in Riverpod, exclusion in admission, sequencing in one engine

## Context and Problem Statement

MADR 0044's phase 4 host verification found a watcher that nothing in the app held
any more: a background tab's watcher kept its host lock and renewed its lease for
more than thirty minutes (0044 PLAN, deviation (c)). The cause was in MADR 0043's
sharing layer, `_SharedWatch`. The maintainer chose to serialize its attach and
detach onto one chain (MADR 0043 amendment 0043.1). As specified, that chain
compared "someone is subscribed" with "a watcher exists" at the moment each step
ran, so a provider rebuild — which cancels the old subscription and subscribes the
new one in the same flush — looked like nothing had changed, and **new watch
parameters were silently dropped**:

```text
existing test "a new subscriber waits for a pending teardown before arming"
  Expected: ['arm', 'teardown', 'arm']
    Actual: ['arm']

scratch: watch recursively, then rebuild with a bounded surface in one flush
  unmodified code (clean worktree at 0d31f51):  arms=[recursive, bounded]  live=1
  serialized chain:                              arms=[recursive]           live=1
```

The maintainer picked a generation-aware chain as the fix, and then asked for
something different in kind: to evaluate the chain and the stack around it with a
new pair of eyes, find **where the design engineered itself into this corner**,
and put together a professional-grade, modular watcher stack — tearing code out
and putting it back correctly if that is what it takes.

This record answers that. It is not the next patch. The question it asks is: *what
shape does the watcher stack need so that this class of defect stops recurring?*

### How this was investigated

Every finding below is drawn from one of these, and each says which:

* **Code read in full or by mapped section:** `watch_lifecycle.dart`,
  `remote_watch_service.dart` (declarations, statics, and the arm closure section by
  section), `local_watch_service.dart`, `repoWatchProvider` and `_withoutIgnoredPaths`
  in `app_providers.dart`, `watch_event.dart`, `watch_diagnostics.dart`, the
  consumers in `repo_status_view.dart`, and `window_manager_bridge.dart`.
* **Framework source read:** Riverpod 3.3.2's `ProviderScheduler`
  (`riverpod-3.3.2/lib/src/core/scheduler.dart`) and flutter_riverpod 3.3.2's
  `UncontrolledProviderScope` and `ConsumerStatefulElement`.
* **Reproductions run** in the gitignored `build/` directory or in scratch
  directories outside the repository, each with a control run through the same
  harness.
* **Measured:** file sizes, commit churn, decision-record coverage, timing constants,
  and the watcher test inventory.

Line numbers cite the committed code at `0d31f51`, which is also what the working tree
now holds: the withdrawn serialized `_SharedWatch` has been discarded.

## Findings

### F1 — Seven concerns, spread across five owners

A repository watcher has seven concerns. Today each is owned in more than one place,
or in a place that cannot own it structurally:

| Concern | Owned today by |
| --- | --- |
| **Demand** — does anyone want events for this repository? | `repoWatchProvider` (autoDispose family) **and** `_SharedWatch`'s broadcast refcount **and** the pop-out bridge's `container.listen` |
| **Identity and parameters** — what exactly is watched? | the provider's `ref.watch(connectionProvider.select(...))` rebuilds; `_SharedWatch.build`, a replaceable closure; `_createLifecycle`'s captured `bounded` argument; `cachedTool`, a closure local |
| **Admission** — may this session start a host process now? | static `_liveByHost` and `_slotReleases`, plus a `releaseSlot`/`armCounted` closure pair inside the arm; same-session exclusion in `_SharedWatch`'s teardown gate |
| **The source process** — arm, run, tear down | one 503-line closure, `_createLifecycle` (`remote_watch_service.dart:651–1153`) |
| **Health policy** — restart, degrade, recover | `watchLifecycle`, a function holding about eighteen captured mutable variables and its own future chain |
| **Output** — coalesced `RepoWatchEvent`s | the lifecycle's coalescer, then `_withoutIgnoredPaths` in the provider |
| **Observability** | `watchDiagnostics`, a process-wide map keyed by bare `repoPath` |

The rest of the findings are the consequences of that table.

### F2 — Sharing was built to solve an exclusion problem

**Riverpod already guarantees one provider instance per family key per container.**
Every widget and the pop-out bridge that watches `repoWatchProvider(path)` shares that
one instance, and so one stream and one lifecycle. The watch services have exactly two
production callers, both inside that provider:

```text
lib/core/providers/app_providers.dart:3744:  ConnectionBackend.local => local.watch(repoPath, bounded: bounded),
lib/core/providers/app_providers.dart:3745:  ConnectionBackend.ssh => remote.watch(repoPath, bounded: bounded),
```

MADR 0043 proved two things. **The teardown seam** (its F3 and F4): a rebuild arms a
new watcher before the old one has released the host lock. And **coexistence** (its
F2): two concurrent `watch()` calls on one service arm twice. The second was
reproduced only by calling the service twice directly; its production route was
never found (0043 F9). What production needed was **exclusion at the seam** — do
not arm repository R until R's previous arm in this session has given back its host
claims. It got **subscription sharing** instead, and every fix since has added state
to that layer:

| Change | Problem it answered | Problem it created |
| --- | --- | --- |
| sharing (`edc06b3`) | coexistence | a layer that owns lifetime as a mutable handle |
| teardown gate (`2cb8f9b`) | the seam | a retained future and a deferred build |
| grace bound | a gate that could wait forever | a timeout coupled to another timeout, in prose |
| serialized chain (0043.1) | the orphan | identity with no parameters in it |
| generation (proposed) | dropped parameters | a fourth hand-rolled sequencer |

**This is the corner.** The premise of the layer did not hold in production, so each
fix makes a mechanism more elaborate that the product does not need.

### F3 — Identity leaves out the parameters

`_SharedWatch` is keyed by `repoPath`. The parameters reach it afterwards, as a
replaceable closure, and the lifecycle captures `bounded` when it is created. So the
key says "the same watcher" while the closure says "a different watcher". Any layer
keyed that way has to infer whether parameters changed from the *timing* of rebuilds,
and the reproduction in the Context above is that inference going wrong. A generation
counter would be the same inference, made more carefully.

### F4 — A running watcher's lifetime is held by a handle that can be overwritten

`_SharedWatch._source` is a mutable field in a map that outlives every subscriber. The
orphan was that field overwritten while the watcher it pointed to kept running,
reproduced with the real `RemoteWatchService` and a 400 ms teardown:

```text
RACE    leave, arrive, leave, arrive inside one teardown; then all leave:  live=1  liveWatchers=1
CONTROL one clean leave and arrive; then all leave:                        live=0  liveWatchers=0
```

When a lifecycle is owned directly by the provider's stream subscription, Riverpod
cancels it on dispose, and there is no intermediate handle to lose.

### F5 — Three hand-rolled sequencers, and a defect at each seam

Ordering is enforced in three places, each an ad-hoc future chain or a set of checks:

* **Within one lifecycle:** `startChain` and `queued` in `watchLifecycle`. It exists
  because of MADR 0026 H1, where two overlapping arms each armed a source and only
  one teardown survived.
* **Across lifecycles:** `_SharedWatch`'s gate, then its chain. MADR 0043's F2 and F3,
  amendment 0043.1's orphan, and this record's dropped parameters all happened here.
* **Across the awaits inside one arm:** `hooks.isCancelled()` checked between steps, and
  the readiness race's `Future.any` (MADR 0044).

Each was correct for the case that produced it, and the defects appeared **where two
of them meet**. The structural alternative is one sequential owner per watcher, in
which every asynchronous result carries the identity of the attempt that asked for
it, so a stale result can be discarded by comparison rather than guarded against by
position.

### F6 — The remote arm is one 503-line closure doing eight jobs

`_createLifecycle`'s arm callback covers, in order: tool probe and its cache; bounded
spec resolution; host ceiling accounting (`_liveByHost`, `releaseSlot`, `armCounted`);
token and lease paths and the awaited first stamp; host-claim release; stream open and
stream budget; the readiness race and refusal decoding; stdout record splitting; bounded
re-arm debouncing; stderr parsing (marker, incumbent, noise, diagnostics budget); the
heartbeat timer; and teardown ordering.

None of these can be tested without a service, an executor and a live event loop. Two
are duplicated verbatim in `LocalWatchService` — the `.git/` re-arm debounce and its
2-second constant (`local_watch_service.dart:182`, `remote_watch_service.dart:574`).
The five coalescing and polling durations are declared in **four** signatures:
`watchLifecycle`, `LocalWatchService.watch`, `RemoteWatchService.watch` and
`_createLifecycle`.

### F7 — Per-session resources are accounted process-wide

`_liveByHost`, `_slotReleases` and `_tokenSeq` are `static`
(`remote_watch_service.dart:462, 504, 512`). The host-wide ceiling is deliberate —
`remoteWatchServiceProvider` says the budget "belongs to the HOST", and MADR 0039 F4
keyed it by host — but it is held as a hidden static rather than as an object someone
owns. Every watcher test has to call `resetWatcherCount()` in `setUp`, and an orphan's
slot is charged against every tab on that host.

### F8 — Time is not injectable

The couplings are real and documented only in prose: `releaseHostClaims` has a
15-second timeout "coupled to" a three-minute grace; a 60-second heartbeat sits against
a five-minute stale lease and a 60-second host-side lease poll. They are `static const`,
so a test cannot shorten them.

The 22 watcher test files contain about 100 real-time waits against 19 `fakeAsync`
uses. This session's false mutation survivors came from exactly those real-time tests
under load (0044 PLAN, phase 3). And the one component that is already a pure engine,
`watchLifecycle`, is tested entirely under `fakeAsync` — 9 of 9 — which is the proof
that the shape works when time is not a hidden dependency.

### F9 — Diagnostics without identity

`WatchTransitionRecord` carries `repoPath`, a cause and a process-wide `liveWatchers`,
but no watcher token and no session. MADR 0043's whole investigation turned on reading
two records as adjacent when they could have come from different lifecycles (its F1).
The token that would settle that already exists for every arm; it just never reaches
the record. The only readers are the two services, which build the Output pane summary.

### F10 — The host lock's key is a path assumption

The remote arm locks `gitDir = spec?.gitDir ?? '$repoPath/.git'`
(`remote_watch_service.dart:771`). For a **linked worktree** or a **submodule**, `.git`
is a *file*, not a directory. Such a path is reachable remotely:
`worktrees_view.dart:474` opens a detached window on `wt.path`, and the bridge watches
that path in the tab's container. `LocalWatchService` resolves the common git dir for a
linked worktree through `probeLocalRepo` (`local_watch_service.dart:132–147`); the
remote side has no equivalent. The awaited first lease stamp swallows its own failure
(`beat()`'s `catch (_) {}`).

**Reproduced**, against a real `sh`, with the exact scripts `remoteWatcherArgs` generates
and a blocking stand-in for `inotifywait`, keyed exactly as the client keys them — a
scratch repository as the control and its linked worktree as the case:

```text
worktree '.git' is a FILE
CONTROL  main checkout  : alive=True  exit=None  armed=True   lock-dir-created=True
CASE     linked worktree: alive=False exit=98    armed=False  stderr=''
CASE     lease stamp    : exit=1  touch: …/wt/.git/mg-watch.<token>.hb: Not a directory
```

Exit 98 is `boundedWatchLockedExit`, and stderr names no incumbent because nothing holds
the lock: `mkdir` beneath a file can never succeed, the prelude's steal path finds no
token, and its second `mkdir` fails as well. The client decodes 98 as
`WatchUnavailableReason.heldByAnother`, so a remote linked worktree **never gets a live
watcher**. It polls, waits out the three-minute recovery, is refused again, and the
Output pane reports "another live watcher already holds" for a lock that nobody holds.
That client-side sequence is read from the arm's refusal branch, not observed in the app.
Submodules were not reproduced; git gives them the same `.git`-file shape, so they are
expected to behave the same way.

This is the same mismatch as F3, one level down: what the client uses as identity (the
path it shows) is not what the host uses as identity (the directory it locks).

### F11 — What is solid, and must be kept

* **The host scripts** — the lock prelude, lease loop, stdin-EOF watchdog and readiness
  marker — are executed by tests and were verified live (MADR 0041; MADR 0044's phase 4).
  This decision does not change the host protocol.
* **`Coalescer`**: two commits in its history, and tested under `fakeAsync`.
* **The `RepoWatchEvent` contract** that consumers depend on: `mode`, `paths`,
  `isScoped`, `touchesGitState`, `touchedAreas`.
* **`_withoutIgnoredPaths`** and the `WatchUnavailableReason` taxonomy. *(The filter's
  contract is kept; its `async*` form is not — see amendment 0045.1.)*
* **The readiness race** and its refusal decoding.
* **The verification assets:** 47 watcher mutations across four catalogues, and the
  consolidated `FakeWatcherHandle`.

The redesign is confined to client-side orchestration.

## Decision Drivers

* **This is a class of defect, not a defect.** A fix should remove the seam where two
  orderings meet, not add a guard at it.
* **One owner per concern, enforced by types and lifetimes** rather than by convention
  and comments.
* **Every guarantee proven today survives**: at most one watcher per repository per
  session; never arming while a predecessor holds the lock; refusals degrade without
  spending the restart budget; the ceiling stays host-wide; the readiness race; a late
  subscriber sees the current mode; `stopped` and `eventDriven` ticks at the same
  transitions; path overflow degrades to an unscoped tick.
* **Deterministic tests**: injected time, and no real-time sleeps in tests of logic.
* **Idiomatic Dart and Riverpod**: value-object family keys, `autoDispose` lifetime,
  sealed states, small composable units, no hidden statics (MADR 0039).
* **Incremental migration**, with the suite green and every mutation catalogue armed at
  each phase boundary (MADR 0039 D9).
* **No change to the host protocol.**

## Considered Options

* **A — Patch in place:** a generation-aware chain inside `_SharedWatch`, the resolution
  offered for 0044 deviation (c).
* **B — Delete sharing; move exclusion into an admission primitive;** Riverpod owns
  demand; keep `watchLifecycle` and the arm closure.
* **C — B, plus identity-keyed targets, one sequential engine, the arm decomposed into
  sources and pure units, injected timings, and identity in diagnostics.**
* **D — Move the watcher into Riverpod notifiers:** an `AsyncNotifier` per target that
  arms, restarts and polls.
* **E — A host-side multiplexer:** one long-lived host process per session streaming
  events for many repositories.

## Decision Outcome

Chosen option: **"C"**, sequenced so that B's content lands first. The orphan class is
live in the running build, and admission is the change that removes it.

C makes each concern structural and gives it exactly one owner.

### 1. Demand and identity: Riverpod, keyed by a value object

`WatchTarget` is an immutable value with `==` and `hashCode`: the repository path, a
sealed `WatchSurface` — `RecursiveSurface`, or `BoundedSurface(gitDir, workTree)` — and
the backend. It carries **static parameters only**. The dynamic part, the tracked-file
set of a bounded surface, stays a supplier that the engine re-arms against, as today.

* **`watcherProvider(WatchTarget)`** is an autoDispose family, and owns one engine for
  its lifetime.
* **`repoWatchProvider(repoPath)`** stays the public name every consumer already uses,
  and becomes a facade: it derives the target from connection state, watches
  `watcherProvider(target)`, and applies `_withoutIgnoredPaths`.
* **A parameter change is a different key.** Riverpod disposes the old engine and
  creates a new one. No closure swap, no generation, no inference from timing.
* **A rebuild with an unchanged target keeps the running engine.** Riverpod 3.3.2 skips
  disposing an element that has regained a listener before its dispose task runs
  (`ProviderScheduler._performDispose` checks `hasNonWeakListeners`). So invalidating
  the facade on a reconnect no longer tears down and re-arms every watcher — which
  removes the reconnect trigger of the orphan rather than surviving it. That comes from
  reading the scheduler source, not from a run; the plan's first provider test must
  confirm it.
* **Transport loss is an engine event.** The source's stream dies with the old
  transport and the engine restarts it with backoff, on the same executor
  (`executorProvider` is stable across redials).

### 2. Exclusion and budget: one admission component, two explicit scopes

`WatchAdmission` replaces `_liveByHost`, `_slotReleases`, `releaseSlot`/`armCounted`
and all of `_SharedWatch`:

* **`HostWatcherBudget`** is process-scoped, and a real object injected into each tab
  container rather than a static. It is keyed by host, with the capacity derived as
  today. The host-wide semantics are unchanged, and 0044 F9's debt stays recorded
  rather than smuggled in here.
* **`RepoExclusion`** is session-scoped, capacity one, keyed by the **lock key — the
  directory the host locks** — not by the path the UI shows. That fixes F10's mismatch
  by construction.
* **`acquire(lockKey, cancel:)`** returns `Admitted(ticket)` or `Refused(ceiling)`
  immediately for the budget. For the exclusion it waits — cancellably, and bounded by
  the admission grace — for the predecessor's ticket. A predecessor releases its ticket
  only after its host claims are gone, which is the MADR 0043 seam, now expressed in one
  place.
* **Tickets are owned by exactly one engine attempt** and released in `finally`.
  `release()` is idempotent. A test can assert that no tickets are outstanding against a
  fresh injected instance, which replaces `resetWatcherCount()`.
* **With Riverpod owning demand, two engines for one lock key coexist only when two
  different targets resolve to the same git dir** — two worktrees of one repository, for
  instance. The second waits, polls with its own reason rather than a false
  `heldByAnother`, and wakes when the lock is released.

### 3. Sequencing: one engine per watcher, one mailbox

`WatchEngine` replaces `watchLifecycle`:

* **A sealed `EngineState`** — idle, arming, armed, backing off, polling, stopped — and
  a sealed set of input events.
* **One mailbox, processed one event at a time.** Side effects — arm a source, tear it
  down, start a timer — are issued by the loop, and their outcomes come back as events
  **tagged with the attempt that issued them**. An outcome whose attempt is not the
  current one is discarded by comparison. That single rule is the structural answer to
  0026 H1, 0043's F2 and F3, amendment 0043.1, and this record's dropped parameters,
  all of which were a late result landing on newer state.
* **Cancellation is a token passed to the source**, instead of polling `isCancelled()`
  between awaits.
* **Timers come from an injected clock and timer factory** (`package:clock` is already
  a dependency), so every engine test runs under `fakeAsync`.
* **The nine `watch_lifecycle_test.dart` tests are the engine's specification**, ported
  with their assertions unchanged. `Coalescer` is reused as is.

### 4. The backend seam: `WatchSource`

The engine's only knowledge of a backend is
`Future<SourceArm> arm(WatchTarget, ArmContext)`. It returns a sealed `SourceArm` — an
armed source, unavailable with a reason, or aborted — and an armed source exposes a
stream of signals (path, activity, re-arm requested, died) and `close()`. The engine
never sees SSH or `dart:io`.

* **`RemoteWatchSource`** is composed of:
  * `WatcherToolProbe` — cached per session, invalidated on recovery;
  * `LockKeyResolver` — the git dir the host will lock, including worktrees and
    submodules;
  * `WatchLease` — token, pid and heartbeat paths, a first stamp that **fails loudly**,
    the heartbeat, and host-claim release;
  * `WatcherProcess` — stream open, readiness race, refusal decoding, close ordering;
  * two pure units, `StderrLineReader` and `RecordSplitter`, testable without a stream.
* **`DirectoryWatchSource`** keeps `probeLocalRepo`'s root resolution.
* **`SurfaceRearmPolicy`** is shared by both, ending F6's duplication.

### 5. Time: one `WatchTimings` value

One immutable object holds every duration the stack uses. Its constructor asserts the
couplings the doc comments currently describe in prose — the release timeout sits below
the admission grace, and three heartbeats fit inside a stale lease. The host-side lease
poll is passed to the scripts from the same object. `WatchTimings.forTest()` shrinks
everything at once, which retires the four duplicated signatures and the scattered
`static const`s.

### 6. Observability: identity on every record

Every `WatchTransitionRecord` carries a `WatcherId`: the session, the target, and the
attempt's token. `liveWatchers` is reported per host, from the budget. The Output
pane's `degradationSummary` keeps its format and gains the token.

### Where it lives

A new `lib/core/git/watch/` directory holds `watch_target.dart`, `watch_timings.dart`,
`engine/`, `admission/`, and `source/` with `remote/` and `local/` beneath it. These
existing files stay where they are, because mutation catalogues anchor to their paths:
`bounded_watch.dart` (host scripts), `coalescer.dart`, `watch_event.dart`,
`watch_path_filter.dart`, and `watch_diagnostics.dart`, extended.
`remote_watch_service.dart` and `local_watch_service.dart` shrink to adapters during
migration and are retired at the end.

### What happens to the work in flight

* **The serialized `_SharedWatch` was never committed, and has been discarded** on the
  maintainer's approval; `remote_watch_service.dart` is back to `0d31f51`. Admission
  deletes `_SharedWatch` altogether.
* **The generation patch is not implemented.** It would add a fourth sequencer to a
  layer this decision removes.
* **The tests written for deviation (c) become acceptance tests of the new design**,
  each at the level that owns its guarantee. The orphan and arm-once-after-teardown
  tests move to admission and the provider; the grace test moves to admission; the
  parameters rebuild moves to target identity.
* **The running build still carries the orphan defect.** The plan lands admission early
  so that the class disappears first.

### Migration sequence (the plan holds the detail)

The executable detail — files, steps, tests, catalogue changes and acceptance per phase — is [0045-PLAN-one-owner-per-watcher-concern.md](0045-PLAN-one-owner-per-watcher-concern.md).

1. **Foundations, no behaviour change:** `WatchTimings`, `WatchTarget` and `WatcherId`;
   the pure units `RecordSplitter`, `StderrLineReader` and `SurfaceRearmPolicy`,
   extracted with their own tests.
2. **Admission:** the budget and exclusion, injected. Delete the statics and
   `_SharedWatch`. Replace 0043's service-level sharing tests with a provider-level test
   that one target has one engine — an explicit change of contract, recorded as such.
3. **Sources:** the `WatchSource` interface, `RemoteWatchSource` with lock-key resolution,
   and `DirectoryWatchSource`. The services delegate to them.
4. **Engine:** `WatchEngine` replaces `watchLifecycle`; the nine lifecycle tests are
   ported; stale-attempt rejection is tested directly.
5. **Riverpod:** `watcherProvider(WatchTarget)` and the facade. Confirm that invalidating
   the facade does not restart an unchanged target.
6. **Observability and tests:** identity on records; move logic tests off real-time
   waits; consolidate the catalogues so every current guarantee still has a mutation
   that kills it.
7. **Host verification:** repeat 0044's phase 4 checks, run a census across a forced
   reconnect, arm a worktree on a real host, and finally measure 0044's 4.3.

### Consequences

* Good, because every seam that produced a watcher defect in MADR 0026, MADR 0043,
  amendment 0043.1 and this record's regression is removed rather than guarded: demand,
  identity, exclusion and sequencing each have one owner.
* Good, because a parameter change becomes a key change that Riverpod handles, and an
  unchanged rebuild — every reconnect — stops restarting every watcher.
* Good, because the stack becomes testable without wall-clock time, which removes the
  source of this session's false mutation survivors.
* Good, because a 503-line closure becomes roughly ten units with one job each, and the
  duplication between the backends ends.
* Good, because F10's lock-key mismatch is fixed by construction, not by special-casing
  worktrees.
* Neutral, because the host protocol is unchanged, so the host-side verification from
  MADR 0041 and MADR 0044 carries over.
* Bad, because this is a multi-phase programme on the subsystem with the longest defect
  history in the repository — 35 commits on `remote_watch_service.dart`, 13 of them
  fixes, and 22 decision records that touch the watcher.
* Bad, because behaviour that no test pins can regress silently. The mitigation is the
  order of work: port the existing specifications before replacing what they specify,
  and require every catalogue to be armed at every boundary.
* Bad, because the orphan defect stays in the running build until phase 2 ships.

## Pros and Cons of the Options

### A — Patch in place

* Good, because it is the smallest change and the fastest to ship.
* Bad, because it adds a fourth hand-rolled sequencer (F5).
* Bad, because identity is still reconstructed from timing (F3), and F4 and F6–F10 stay
  exactly as they are.
* Bad, because the next piece of state added to `_SharedWatch` reopens the class.

### B — Admission only

* Good, because it removes the orphan and the dropped parameters at their root: with no
  intermediate lifetime layer, there is no handle to lose and no closure to swap.
* Good, because it is a medium-sized change that lands early.
* Bad, because it keeps the 503-line closure, the closure-based engine, time that cannot
  be injected, diagnostics without identity, and the lock-key mismatch (F6, F8, F9, F10).

### C — One owner per concern

* Good, for every reason listed under Consequences.
* Neutral, because it is delivered in phases, and B's content is the first of them.
* Bad, because it is the largest change of the five, and needs discipline at every
  migration boundary.

### D — Riverpod notifiers

* Good, because state management would be idiomatic and discoverable.
* Bad, because SSH and process orchestration and timers would live inside providers,
  coupling core transport logic to the framework — the opposite of `AGENTS.md`'s split
  between `lib/core` and `lib/features`.
* Bad, because a notifier's rebuild semantics reintroduce the dispose-and-create seam for
  long-lived I/O that this record exists to remove.
* Bad, because pop-out secondary engines override these providers.

### E — Host-side multiplexer

* Good, because one channel per session would sidestep stream budgets and the per-watcher
  ceiling.
* Bad, because it means installing, versioning and securing a daemon on every host,
  against the app's posture of needing nothing on a host beyond git and a watcher tool.
* Bad, because its cost is out of proportion to a class of defect that lives entirely in
  client orchestration.

## Confirmation

* **Every reproduction becomes a regression test that fails against today's tree
  first:** the orphan, arm-once-after-teardown, the grace bound, the parameters rebuild,
  stale-attempt rejection, and the lock key when F10 is confirmed.
* **Existing specifications carry over:** the nine lifecycle tests; the refusal and
  readiness tests in `watch_arm_signal_test.dart`; the executed host-script tests (the
  scripts are unchanged); and the 0041, 0043 and 0044 mutation catalogues, re-armed at
  every phase boundary.
* **Structure is enforced by source scans, not by prose:** no mutable `static` in the
  watch stack; `watchLifecycle` and `_SharedWatch` gone.
* **Live:** repeat MADR 0044's phase 4 checks; run a forced reconnect under a host-side
  sampler, with no lease surviving the teardown; arm a linked worktree on a real host.

The limits: the claim in section 1 that an unchanged-target rebuild keeps its engine
comes from reading Riverpod's source, not from a run, and the plan confirms it first.
F10 is reproduced at the script level; the client's decoding of it, and a linked worktree arming on a real host, are confirmed in the plan's final phase.

## Amendments

### 0045.1 — the ignored-path filter did not pass cancellation through (2026-09-10)

**What F11 got wrong.** F11 listed `_withoutIgnoredPaths` as solid. Its contract is; its
implementation was not. Since it was added in `d3b2fda` (2026-07-13) it has been an `async*`
function looping `await for` over the watcher's stream, while its doc comment describes an
`asyncMap`. Cancelling an `async*` stream takes effect only at its next `yield`
(`_AsyncStarStreamController.onCancel` in the VM: "Cancellation does not affect an async
generator that is suspended at an await"), so when the last listener left
`repoWatchProvider`, Riverpod disposed the provider and the watcher under it kept running
until its next event. For a quiet repository that is its host process, lease, host lock and
budget slot, for as long as the repository stays quiet. Observed with scratch probes on the
phase-2 tree and on a clean worktree of `4e4a854`: `exists=false cancelled=false`, then
`cancelled=true` after one event.

**Why it surfaced now.** `_SharedWatch` masked it: a view returning to the repository
re-attached to the still-live watcher. Under section 2 it cannot — the returning listener's
new watcher waits on the stale one's exclusion hold, and a probe showed it with no mode after
three seconds. Section 1's premise that the last listener leaving tears the watcher down was
true of Riverpod and false of this stream.

**Decision.** The filter becomes `raw.asyncMap(…)` with empty results dropped — what its doc
comment already said. `Stream.asyncMap` sets `controller.onCancel = subscription.cancel`, so
cancellation reaches the watcher at once, and pauses its source while a classification is
pending, so ticks stay ordered. Its four behaviours are unchanged and are now each pinned at
the provider level, where none was tested before; a returning listener on a quiet repository
is pinned too. Phase 5's facade keeps the corrected filter. The plan's deviation (d) holds
the evidence and the execution.

## More Information

* **Records this changes.**
  [0043-MADR-a-watcher-refused-by-its-own-session.md](0043-MADR-a-watcher-refused-by-its-own-session.md)
  — its sharing mechanism (Decision Outcome items 1–3) and amendment 0043.1's serialized
  chain are superseded here, by amendment 0043.2.
  [0044-PLAN-the-watcher-follows-the-active-tab.md](0044-PLAN-the-watcher-follows-the-active-tab.md)
  — step 4.7 is superseded, and deviation (c) records the revised resolution; phase 4.3
  waits on this record's plan.
* **The history this record draws on.** MADR 0026 H1 (the first sequencer, and the seam
  it closed); MADR 0028 H2 (the ceiling wake that admission keeps); MADR 0039 F4 and D9
  (the host-keyed ceiling as a static, and catalogues armed at every boundary); MADR
  0040 and 0044 F9 (the ceiling's derivation, left as it is); MADR 0041 (the host
  protocol this record does not touch).
* **Framework source read:** `riverpod-3.3.2/lib/src/core/scheduler.dart`
  (`_scheduleTaskWithVsyncs`, `_performDispose`);
  `flutter_riverpod-3.3.2/lib/src/core/provider_scope.dart`
  (`_UncontrolledProviderScopeState`); `flutter_riverpod-3.3.2/lib/src/core/consumer.dart`
  (`didChangeDependencies`, `unmount`).
* **Scratch reproductions** (gitignored `build/`, not committed):
  `tab_swap_dispose_test.dart` — an in-place container swap disposes the background
  container's provider in both directions; `shared_race_test.dart` — the orphan, with its
  control; `rebuild_params_test.dart` — the dropped parameters, run against the rewrite
  and against a clean worktree of the unmodified code.
