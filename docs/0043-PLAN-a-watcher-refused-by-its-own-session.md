---
status: "proposed"
date: 2026-09-09
associated-madr: "0043-MADR-a-watcher-refused-by-its-own-session.md"
---
# Implement: one watcher per repository, decided by the client

Associated MADR:
[0043-MADR-a-watcher-refused-by-its-own-session.md](0043-MADR-a-watcher-refused-by-its-own-session.md)

## Goal

Make it impossible for one session to arm the same repository twice, so that
`heldByAnother` can only ever mean what it says — another session — and a
healthy repository never degrades to polling because it collided with itself.

Four phases, one commit each. Phase 4 is droppable; phases 1–3 land in order.

## Assessment of the MADR before planning on it

Two things were checked before writing a step, and one of them changed the
decision.

| MADR claim | Checked how | Result |
| --- | --- | --- |
| `RemoteWatchService` has no same-path guard | two concurrent `watch()` calls, fake executor | **Holds** — 2 watchers, 2 tokens, 2 slots, 2 `armed` records |
| A Riverpod `invalidate()` arms gen 2 before gen 1's teardown finishes | minimal provider mirroring `repoWatchProvider` | **Holds** — but `onCancel` still fires *first* |
| A dependency-driven rebuild might order create-before-dispose | same probe, dependency changed instead | **No** — also dispose-first |
| The decision (serialise arms against teardowns) fixes the reported incident | read against F1 | **NO — it does not** |

That last row is the important one. F1 establishes the first watcher was
**still running** when the second was refused; there is no teardown in flight
for a queue to wait on. A gate keyed on teardowns would have shipped, passed its
own tests, and left the reported symptom untouched.

**The MADR has been corrected** — the decision now reads C as *sharing* (a
second subscriber attaches to the existing watcher) with the teardown gate
covering only the seam where the last subscriber leaves and a new one arrives.
This plan implements the corrected decision.

The measured rebuild ordering, for both routes:

```text
teardown-start:1     <- onCancel first, in BOTH cases
ARM-start:2
ARM-done:2
teardown-done:1
```

which also narrows MADR F9: no rebuild can produce F1's record pair, because
every rebuild records `stopped` before the new arm. The two subscriptions in the
reported session were concurrent, not sequential.

## Scope

**In scope**

* `lib/core/git/remote_watch_service.dart` — the shared-watch map, the teardown
  gate, the awaited lock release, the refusal-path lease cleanup.
* `lib/core/git/bounded_watch.dart` — a token-guarded lock-release fragment the
  client can issue, and (phase 4) the refusal naming its incumbent.
* `test/watch_shared_path_test.dart` — new.
* `test/watch_lease_release_test.dart`, `test/watch_lease_teardown_exec_test.dart`
  — extended.
* `tool/mutations/0043-one-watcher-per-repo.json` — new.

**Explicitly out of scope**

* `watchLifecycle` itself. Its `startChain` already serialises arms within an
  instance (MADR 0026 H1) and is not implicated; this is the gap *between*
  instances.
* The host-side lock's steal rule, refusal status, and sweep. They are correct
  and stay exactly as they are — the point of this work is to stop reaching them
  by accident.
* Process-wide sharing across tabs. Two tabs are two sessions with two
  connections; the host lock is the right mechanism there and MADR 0041 F12
  built it for that (MADR 0043 Decision Outcome, "Deliberately not
  process-wide").
* Re-keying `watchDiagnostics` away from bare `repoPath`. Named as a liability in
  the MADR's More Information; it was also the thing that made F1 legible, and
  changing it is a separate decision.
* Identifying what created the second subscription (MADR F9). This plan closes
  the class; naming the trigger would be additional, not alternative.

## Implementation Steps

### Phase 1 — one watcher per repository path, shared

The phase that fixes the reported incident. Everything else is a seam around it.

**1.1** Add a private `_SharedWatch` to `remote_watch_service.dart` holding, for
one repository path: the lazily-created `watchLifecycle` stream, its
subscription, a broadcast controller, and the last `RepoWatchEvent` seen.

Refcounting is **not** hand-rolled. `StreamController.broadcast` fires `onListen`
when the first listener attaches and `onCancel` when the last one leaves, which
is precisely the count required:

```dart
StreamController<RepoWatchEvent>.broadcast(
  onListen: _attach,   // create the watchLifecycle stream, subscribe once
  onCancel: _detach,   // cancel it -> stop() -> host teardown
);
```

Creation must be lazy — inside `onListen`, not at map insertion — so that a
`watch()` whose stream nobody listens to arms nothing.

**1.2** `RemoteWatchService` gains `final Map<String, _SharedWatch> _shared = {}`,
an **instance** field. Not static: sharing is scoped to one service, which is one
connection, which is one tab (MADR Decision Outcome). A static map would make two
tabs share one watcher across two different connections, which is wrong, and
would re-create exactly the process-global coupling MADR 0039 spent ten phases
removing.

**1.3** `watch()` looks the path up, creating the entry on first use, and returns
a per-subscriber stream. Each subscriber gets the retained last event
immediately, then the live feed:

```dart
Stream<RepoWatchEvent> subscribe() => Stream.multi((c) {
  final sub = _out.stream.listen(c.add, onError: c.addError, onDone: c.close);
  c.onCancel = sub.cancel;
  final last = _last;
  if (last != null) c.add(last);   // AFTER subscribing, so nothing is missed
});
```

The replay matters: `watchLifecycle` emits on arm and then only on events or
poll ticks, so without it a late subscriber's mode indicator sits `loading` —
possibly for a long time on a quiet, event-driven repository.

**1.4 — the parameter question, settled explicitly.** `watch()` takes six timing
parameters besides `bounded`. The first subscriber's values are the ones the
shared watch is created with; a later subscriber's are ignored. This is safe
because `repoWatchProvider` is the only production caller and passes only
`bounded`, itself derived from `connectionProvider.scopedGitDirFor(repoPath)` —
the same value for the same path in the same container. Document it at the
method, and pin it with a test rather than leaving it to be discovered.

**1.5 — tests** (`test/watch_shared_path_test.dart`, new):

| Case | Assertion |
| --- | --- |
| two concurrent `watch()` for one path | **one** arm, one token, one slot |
| both subscribers | receive the same events |
| a late subscriber | receives the current event immediately, without waiting for a tick |
| first subscriber cancels, second remains | watcher stays armed; no teardown |
| last subscriber cancels | teardown runs; the slot is released |
| two *different* paths | two watchers, unchanged from today |
| a second service instance, same path | two watchers — sharing is per-service, per 1.2 |

The first case is MADR F2's reproduction inverted. Run it against the current
tree first and watch it report 2; that is the check earning its keep.

**Acceptance:** `flutter analyze` clean; the new file passes; the existing watcher
suite passes unedited except where a test deliberately built two watchers for one
path (see 1.6).

**1.6 — expected fallout.** Existing tests that call `service.watch('/repo')`
twice for one path now get one watcher. `watch_ceiling_*` tests use *distinct*
paths (`/a`, `/b`, `/one`) and are unaffected; `watch_lease_identity_test.dart`
deliberately arms the same path twice **sequentially** (cancel, then re-watch) to
assert distinct tokens — sequential, so still two watchers, still passes. If
anything else breaks it is a deviation: stop and record it.

---

### Phase 2 — teardown releases its own lock, and the next arm waits for it

Closes the seam: last subscriber leaves, teardown starts, a new subscriber
arrives before the host has released the lock (MADR F3, F4).

**2.1** Add a token-guarded release fragment to `bounded_watch.dart`, mirroring
the host-side `cleanup()` trap's own guard exactly:

```sh
[ "$(cat <lockdir>/token 2>/dev/null)" = <token> ] && rm -rf <lockdir>
```

The guard is not optional. Without it a client tearing down could delete a lock
that a *different* watcher has legitimately taken over in the interval — the
same reasoning that put the guard in the trap.

**2.2** The `WatchArmed` teardown issues that removal and **awaits** it, after
`handle.cancel()`. Bounded (short timeout) and swallowing, exactly as
`releaseLease()` is: a teardown during a disconnect has no executor to talk to
and must not fail or stall for it.

Ordering, and the reason for it: `handle.cancel()` first, because the channel
close is the sub-second path that usually releases the lock on its own; the
explicit removal is the guarantee that the *next* arm can rely on rather than
the mechanism that normally does the work.

**2.3** `_SharedWatch` retains the teardown future. `watch()` for a path whose
entry is mid-teardown awaits it — bounded — before creating a fresh lifecycle. A
timeout here yields today's behaviour (a possible race), never a hang: a
repository must not be able to become permanently unwatchable because one
teardown wedged.

**2.4 — tests.** In `test/watch_lease_teardown_exec_test.dart`, against the real
generated script and real processes: arm, tear down, and immediately re-arm the
same lock directory — the new arm must acquire, not be refused. Today this races
(MADR F4 measured the window at sub-second); run it against the current tree and
watch it fail intermittently before relying on it. If it cannot be made to fail
on demand, say so and record what the test actually establishes.

In `test/watch_lease_release_test.dart`: the teardown issues a lock removal
naming this token, and a removal that throws does not fail the teardown.

**Acceptance:** an arm immediately following a teardown of the same path
acquires; teardown still completes when the executor is gone.

---

### Phase 3 — a refused arm cleans up after itself

**3.1** Hoist `releaseLease()` out of the `WatchArmed` closure to somewhere the
refusal path can reach — it is currently unreachable from there, which is why
every refusal strands a heartbeat (MADR F6, four of them observed).

**3.2** Call it on the `heldByAnother` path, and on the `noWatchedPaths` path,
which strands one for the same reason.

**3.3 — tests.** In `test/watch_lease_release_test.dart`: a refused arm issues a
removal for its own heartbeat and leaves no other trace; the slot is still
released; the diagnostic and record are unchanged.

**Acceptance:** a refusal leaves no `mg-watch.<token>.hb`.

---

### Phase 4 — say who holds it *(droppable)*

Small, and earns its place from this investigation: the refusal currently says
"another live watcher already holds this" without saying which, and establishing
that the "other" watcher was this same session took a host census, an SSH
session audit, and a maintainer confirmation.

**4.1** The lock prelude already reads the incumbent token into `$o` to decide
whether to steal. On the refusal branch, emit it on stderr before exiting 98 —
stderr is already read and forwarded to `onDiagnostic`
(`_isWatcherStartupNoise` filtering aside).

**4.2** Surface it in the refusal diagnostic, so the message names the holder.

**4.3 — tests.** Composition only for the script text (MADR 0029: a `contains`
may pin composition, never behaviour), plus one executing case in
`watch_lease_teardown_exec_test.dart` asserting the refusal's stderr names the
incumbent token — behaviour, executed.

**Acceptance:** a refused arm's diagnostic names the token holding the lock.

---

## Verification

At every phase boundary, not only at the end:

```sh
flutter --version | head -1                # must match FLUTTER_VERSION (3.47.2)
flutter pub get --enforce-lockfile         # "Got dependencies!"
flutter analyze                            # clean
dart format --output=none --set-exit-if-changed lib test
flutter test                               # full suite
tool/mutate.py tool/mutations/0043-one-watcher-per-repo.json
tool/mutate.py tool/mutations/0041-watcher-teardown.json   # the subsystem's existing catalogue
```

Redirect long output to a file and read it back; never put a filter between a
gate and its verdict.

### Mutation catalogue

`tool/mutations/0043-one-watcher-per-repo.json`, run in full at every phase
boundary. MADR 0039 D9's rule, and 0041's execution broke two anchors exactly
this way — expect it here too, and re-anchor rather than skipping.

| Label | Mutation | Killed by |
| --- | --- | --- |
| sharing is removed; each `watch()` arms its own | bypass the map lookup | 1.5 case 1 |
| the shared watch is created eagerly, not on first listen | move creation out of `onListen` | a `watch()` never listened to must arm nothing |
| the last event is not replayed | drop the `_last` emit | 1.5's late-subscriber case |
| teardown fires on the first cancel, not the last | tear down in the per-subscriber `onCancel` | 1.5's "first cancels, second remains" |
| the map is static | `final` → `static final` | 1.5's second-service case |
| the lock release loses its token guard | drop the `[ "$(cat …)" = tok ]` test | 2.4's foreign-lock case |
| the teardown does not release the lock | remove the awaited removal | 2.4 |
| the re-arm does not wait for a pending teardown | drop the await in 2.3 | 2.4 |
| a refused arm strands its heartbeat | remove the 3.2 call | 3.3 |

### Checks seen to fail

Two are available as pre-existing failures rather than synthetic ones, and both
must be run against the **current** tree first:

* MADR F2's reproduction reports **2 watchers** today. After phase 1 it must
  report 1. That inversion is the phase's whole contract.
* An arm issued immediately after a teardown of the same path is refused today,
  intermittently, against a real host (MADR F4's sub-second window). If it
  cannot be provoked reliably, record what the test actually establishes rather
  than reporting it as verification.

Everything else goes through the catalogue, in a scratch `git worktree` — never
by dirtying the tree, and never undone with `git checkout --`.

### Host verification, which needs the maintainer

| Check | Where |
| --- | --- |
| the unit and executing suites | here |
| one repository, one watcher, under real use | here, with a real build |
| `heldByAnother` no longer appears for a single-tab session | **the maintainer's session** — it is the reported symptom |
| two tabs on one repository still produce exactly one watcher and one honest refusal | **the maintainer's session** — the cross-session case must be *preserved*, and this is the check that the fix has not disabled the feature it protects |

That last row is the one to be careful about. This work makes the client stop
reaching the lock by accident; it must not make it stop reaching the lock at
all.

## Rollout and Rollback

* One commit per phase, `git commit --no-edit` only — the hook writes the
  message. Code and docs in separate commits (MADR 0039 D4).
* Nothing is pushed unless asked for in the same turn.
* `git revert` per phase. Ordering: phase 2 builds on phase 1's `_SharedWatch`
  (it stores the teardown future there), so reverting phase 1 alone would not
  compile — revert 2 first. Phases 3 and 4 are independent in both directions.
* A rebuild is required to see any of this; the behaviour is in the client, and
  the reported symptom only appears against a real host.

## Decisions the maintainer should confirm before execution

1. **Sharing versus exclusion.** This plan attaches a second subscriber to the
   existing watcher. The smaller alternative is to refuse it with a new,
   honest reason (`alreadyWatchedHere`) and let it poll — less machinery, but it
   leaves a subscriber polling while a perfectly good watcher for that exact
   repository is live in the same process. Recommendation: **sharing**, because
   the second subscriber is not doing anything wrong and there is no reason it
   should get a worse answer.
2. **Phase 4 in or out.** It is small and it is the diagnostic whose absence
   made this investigation long. Recommendation: **in**.
3. **The bounded timeout in 2.3.** A pending teardown blocks a new arm for at
   most this long before proceeding anyway. Recommendation: a small number of
   seconds — long enough to cover F4's sub-second window with margin, short
   enough that a wedged teardown costs one slow arm rather than a visibly stuck
   repository.

## Deviations

*(None yet — added here, dated, as execution finds them, per the rule that a
deviation is prompted on and recorded before it is executed.)*

## Execution record

*(Added per phase as it lands: what the phase did, the verification output
rather than a summary of it, and what was not done and why.)*
