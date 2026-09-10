---
status: "in-progress"
date: 2026-09-10
associated-madr: "0044-MADR-the-watcher-follows-the-active-tab.md"
---
# Implement option E: settle an arm on a signal instead of a timeout

Associated MADR: [0044-MADR-the-watcher-follows-the-active-tab.md](0044-MADR-the-watcher-follows-the-active-tab.md)

## Goal

Remove the fixed 250 ms wait every watcher arm pays, by settling the arm on
whichever of two signals arrives first — a **refusal exit status** or an
explicit **readiness marker** — rather than on a clock.

MADR 0044 F7 measured an arm at ~400 ms, of which 250 ms is
`handle.exitCode.timeout(const Duration(milliseconds: 250))`
(`remote_watch_service.dart:878`). A healthy watcher never completes `exitCode`,
so that quarter-second is paid in full on every arm: every tab switch, every
restart, every recovery from polling, and the first arm after connect. Replacing
it with a race takes an arm to roughly three round trips — ~150 ms of transport
plus one more for the marker, so **~200 ms against ~400 ms** on the reporting
host.

Two things this must not do, because both are what the 250 ms is actually for:

* a **lock refusal** (`boundedWatchLockedExit`, 98) must still degrade to
  polling immediately, still name its incumbent, and still release the lease it
  stamped;
* a **no-watchable-paths refusal** (`boundedWatchNoPathsExit`, 97) must do the
  same.

Neither may become a watcher that "armed and died", which spends three doomed
restarts before polling (0022 M6).

## Scope

### In

* `lib/core/git/bounded_watch.dart` — emit the readiness marker.
* `lib/core/git/remote_watch_service.dart` — race it; move the stderr listener
  above the race; delete `_incumbentToken`.
* **All eleven** test doubles that stand in for a live watcher, consolidated
  into one `test/helpers/fake_watcher_handle.dart` — see deviation (b) and MADR
  amendment 0044.2. The plan originally said "four", which was wrong by seven.
* New tests for the race itself (`test/watch_arm_signal_test.dart`).
* `tool/mutations/0044-arm-readiness.json`, and re-anchoring of
  `0041-watcher-teardown.json` / `0043-one-watcher-per-repo.json` where this
  work moves their anchors.

### Out

* **Option D** (a "changed while you were away" indicator) is deliberately not
  planned here. MADR 0044 recommends it *conditionally* — only if the goal is
  genuinely to know what a background repository did — and that is a product
  decision the record does not make. It needs its own MADR, because it is a
  feature, not an optimisation.
* **Option C** (keeping the mutable provider graph alive across tabs) is out for
  the same reason, more strongly: 0044 F5 and F6 are the argument against
  smuggling it in.
* `maxConcurrentWatchers`' host-wide derivation from one session's channel
  budget (0044 F9). Known to be inaccurate under concurrent watching, harmless
  today, and only payable if C or D is ever taken up. Left as written debt.
* The single-active-mount model itself (`tabs_host.dart:520`). Untouched.

### Amendment already made

`0044.1` in the MADR: the record's option E said "the first byte of stdout
proves the watcher armed". It does not — `inotifywait -m … --format %w%f` and
`fswatch -0` write only event records, and a repository at rest produces none.
The MADR is amended in place, struck through rather than rewritten. This plan
implements the corrected mechanism.

## Implementation Steps

### Phase 1 — the host scripts emit a readiness marker

**File: `lib/core/git/bounded_watch.dart`**

1.1 Add the marker constant and its fragment builder, beside
`boundedWatchLockedExit`:

```dart
/// The line a watcher writes to **stderr** once it holds every claim it needs
/// and its watcher process has been started.
///
/// stderr, not stdout, for three reasons that all matter. stdout is the event
/// channel and is parsed as delimited records, so a marker there would have to
/// be filtered out of every event path. stderr is unbuffered by POSIX, so the
/// line leaves the host the moment it is written rather than sitting in a
/// stdio buffer the way inotifywait's own output does without `stdbuf -oL`.
/// And there is already a precedent for a script-authored line the client
/// matches — `_lockPrelude` writes `mg-watch: lock held by $o` here.
///
/// **Its position in the script is the whole guarantee.** Both refusals exit
/// before it: `boundedWatchNoPathsExit` from the existence filter, and
/// `boundedWatchLockedExit` from `_lockPrelude`. So this line cannot be
/// produced by an arm that was refused, which makes the client's race
/// well-ordered rather than a matter of timing (MADR 0044 amendment 0044.1).
const String watchArmedMarker = 'mg-watch: armed';

String _armedMarker() =>
    'echo ${ShellEscaper.escape(watchArmedMarker)} >&2; ';
```

1.2 In `_leaseLoop`, emit it immediately after the watcher is started —
**after** the lease-alive check, so a stale lease still exits silently:

```dart
      '{ $inner; } & w=\$!; '
      '${_armedMarker()}'
      '( cat <&3 >/dev/null 2>&1; kill -TERM "\$\$" 2>/dev/null ) & e=\$!; '
```

This one edit covers all three leased forms — `boundedInotifyScript`,
`boundedFswatchScript` and `recursiveWatchScript` all route through
`_leaseLoop`, and `recursiveWatchScript` has no unleased branch at all.

1.3 In `boundedInotifyScript`'s `heartbeat == null` branch, before the exec:

```dart
    return '$prelude'
        '${_armedMarker()}'
        'if command -v stdbuf >/dev/null 2>&1; then '
```

1.4 The same in `boundedFswatchScript`'s `heartbeat == null` branch:

```dart
    return '$prelude${_armedMarker()}exec fswatch -0 --latency 0.5 "\$@"';
```

These two branches are legacy: the production call site at
`remote_watch_service.dart:842` always passes a non-null `heartbeat`. They are
covered anyway so that the marker is a property of the script builders rather
than of one call path.

**File: `test/watch_lease_teardown_exec_test.dart`** — three executing tests,
in the existing `one watcher per repository` group, using the same real-`sh`
harness the file already has:

1.5 *"a refused arm emits no readiness marker"* — take the lock with token `a`,
stamp a fresh lease for it, then run the token-`b` script. Assert exit 98
**and** that its stderr contains `mg-watch: lock held by` and does **not**
contain `watchArmedMarker`.

1.6 *"an arm with no watchable paths emits no readiness marker"* — build a
`boundedInotifyScript` over paths that do not exist. Assert exit 97 and no
marker.

1.7 *"a successful arm emits the marker before any event"* — run the leased
recursive script with the `sleep`-symlink stand-in the file already uses for the
watcher, and assert the marker appears on stderr while the process is still
running and stdout is still empty. This is the one that pins ordering, and it is
the reason these are executing tests rather than `contains()` on script text
(MADR 0029).

**Verify**

```sh
flutter analyze
flutter test test/watch_lease_teardown_exec_test.dart
flutter test test/bounded_watch_test.dart test/remote_watch_service_test.dart
```

**Commit** (`git commit --no-edit`, code only).

### Phase 2 — the client races the marker against the exit status

**File: `lib/core/git/remote_watch_service.dart`**

2.1 Replace the `250 ms` constant with a named ceiling, next to the other
watcher constants:

```dart
/// Upper bound on how long an arm waits for either signal before giving up on
/// both and treating the watcher as armed.
///
/// **This is a backstop, not a cost.** One of the two signals always arrives:
/// a refusal completes `exitCode` in well under a round trip, and a healthy
/// arm writes [watchArmedMarker] to stderr as its next act. Reaching this
/// ceiling means a host that produced neither, which is the case the old fixed
/// 250 ms wait handled by accident. Generous, because nothing waits it out in
/// practice — where the 250 ms it replaces was paid by every arm that
/// succeeded (MADR 0044 F7).
static const Duration armSignalCeiling = Duration(seconds: 2);
```

2.2 **Move the stderr listener above the race.** Today it is attached at
`remote_watch_service.dart:1026`, after the refusal checks. It must move to
immediately after the `hooks.isCancelled()` guard that follows `executeStream`,
and take on two more jobs. Keep the existing diagnostics behaviour byte for
byte — the line budget, `_isWatcherStartupNoise`, `developer.log`,
`onDiagnostic` — and add, per line:

```dart
if (line == watchArmedMarker) {
  if (!ready.isCompleted) ready.complete();
  continue;                      // not a diagnostic; not noise to report
}
final held = _lockHeldBy.firstMatch(line);
if (held != null) incumbent ??= held[1];
```

with `final ready = Completer<void>();` and `String? incumbent;` declared just
above the listener.

Three consequences to hold onto, each of which is why this is a move rather
than a second listener:

* `_OpenHandle` in `watch_lease_release_test.dart` backs stderr with a
  **single-subscription** `StreamController`. One listener, always, is the only
  shape that works — and it is now the shape the production code has.
* dartssh2's `SSHSession._stderrController` queues unread stderr in the Dart
  heap (the comment at `remote_watch_service.dart:1010` says so). Attaching
  earlier strictly reduces that window.
* stdout stays unlistened across the race, exactly as it is today. The window
  gets shorter, not longer, so this introduces no new buffering hazard.

2.3 Replace the early-exit block (`remote_watch_service.dart:876-884`) with the
race:

```dart
typedef _ArmProbe = ({int? exit, bool ready});

final probe = await Future.any<_ArmProbe>([
  handle.exitCode.then((c) => (exit: c, ready: false)),
  ready.future.then((_) => (exit: null, ready: true)),
]).timeout(
  armSignalCeiling,
  onTimeout: () => (exit: null, ready: false),
);
final early = probe.exit;
```

`Future.any` completes on the first future and drops the rest (it guards its
completer), and `SSHSession.waitForExit` is safe to await more than once — so
the losing future needs no cleanup. A record rather than a sentinel exit code,
because `exitCode` is legitimately `null` for a process killed by a signal and
a sentinel would collide with it.

The two refusal branches below are unchanged in behaviour. Only the incumbent
lookup changes.

2.4 **Delete `_incumbentToken`** (`remote_watch_service.dart:521-533`) and its
own 250 ms `stderr.join()` timeout. The refusal branch reads the captured
variable instead:

```dart
final held = incumbent == null ? '' : ' (token $incumbent)';
```

`_lockHeldBy` stays; it moves from being read once on the refusal path to being
matched per line by the listener. **This makes the refusal path faster too** —
it was paying up to 250 ms of its own to find out who held the lock.

2.5 Both refusal branches must now also cancel the stderr subscription before
`handle.cancel()`, mirroring the `WatchArmed` teardown's
`sub.cancel(); errSub.cancel(); handle.cancel();` ordering.

2.6 The `WatchArmed` teardown keeps `errSub.cancel()` where it is. The listener
moved; its lifetime did not.

**Files: the four test doubles.** Each stands in for a live watcher whose
`exitCode` never completes, so each currently *pays* the 250 ms and would
otherwise wait out the new 2 s ceiling — turning a correctness change into a
suite that takes minutes longer. Each must emit the marker, and the emission
must be **on the controller's `onListen`**, not in the constructor: these fakes
use broadcast controllers, which drop what is added before a listener attaches.
The real SSH stream queues instead, which is exactly the difference that would
let a fake lie about ordering.

* `test/watch_shared_path_test.dart` — `_Handle` (~11 tests, several arming
  twice).
* `test/watch_lease_release_test.dart` — `_OpenHandle`; and the comment at
  line 188 documenting the 250 ms cap must be rewritten to describe the race.
  `_ExitedHandle` is a refusal double and must **not** emit the marker — that
  is the point of it.
* `test/helpers/mock_executor.dart` — `MockStreamHandle`: add an
  `emitArmed()` helper and default new handles to emitting on first listen,
  since every watcher test in the suite goes through it.

**New test: `test/watch_arm_signal_test.dart`**

* *"an arm settles on the marker, not the ceiling"* — a handle whose `exitCode`
  never completes and which emits the marker on first listen. Assert the arm
  reaches `WatchArmed` and that elapsed wall time is below 250 ms, i.e. below
  the constant this change deletes. The bound is the assertion: it fails if the
  race is not actually racing.
* *"a lock refusal is still a refusal, and still names its incumbent"* — a
  handle that writes `mg-watch: lock held by zzz` and exits 98. Assert
  `WatchUnavailableReason.heldByAnother`, the diagnostic containing
  `token zzz`, and that the lease-release command was issued.
* *"an arm with neither signal gives up at the ceiling and treats the watcher
  as armed"* — a silent handle. Assert `WatchArmed` after `armSignalCeiling`,
  proving the backstop is a backstop and not a hang.
* *"a marker arriving after the ceiling does not re-settle a settled arm"* —
  guards the `ready.isCompleted` check.

**Verify**

```sh
flutter analyze
flutter test test/watch_arm_signal_test.dart
flutter test test/watch_shared_path_test.dart test/watch_lease_release_test.dart \
             test/watch_ceiling_derived_test.dart test/watch_lease_teardown_exec_test.dart
flutter test
```


#### Step 2.7 — one double for the watcher channel (added by deviation (b))

`test/helpers/fake_watcher_handle.dart`, a single `FakeWatcherHandle`
implementing `CommandStreamHandle`, with **named constructors for the three
scenarios that actually differ** rather than a widening set of flags:

| Constructor | Models | Marker | `exitCode` |
| --- | --- | --- | --- |
| `FakeWatcherHandle.armed()` | a watcher that armed and is waiting — the healthy steady state | yes | never completes |
| `FakeWatcherHandle.refused(code, {stderrLine})` | a script-level refusal | **no** | completes with `code` |
| `FakeWatcherHandle.silentHost()` | a host that emits neither signal — the ceiling's reason to exist | no | never completes |

Everything the eleven doubles vary on becomes an option on `armed()`, because
each is something a test asserts about rather than a different kind of channel:

* `cancelDelay` — the teardown window MADR 0043 F4 measured on a real host,
  which `watch_shared_path_test.dart` needs to observe ordering;
* `onTeardown` — a callback, replacing the `_log.add('teardown')` and the bare
  `cancelled` flag with one seam (`cancelled` stays, as a field);
* `emitStdout` / `emitStderr` / `delivered` — from `_DrivableStreamHandle`,
  whose `delivered` counter is how a test knows the service's listener body has
  actually run.

Two properties the consolidated double must keep, both learned the hard way and
currently visible in only one copy each:

* **`cancel()` must not await the close of an unsubscribed controller.**
  `_ExitedHandle` carries the finding: a refusal is torn down before the stdout
  listener is attached, and closing an unsubscribed single-subscription
  controller returns a future that never completes — `await handle.cancel()`
  hangs and the arm never returns. The real handle closes an SSH session and has
  no such wait.
* **The readiness marker is emitted on first listen, never from the
  constructor.** A broadcast controller drops what is added before a listener
  attaches, where the real SSH stream queues it. A double that announced early
  would settle the arm before the race began and prove nothing about the
  ordering it exists to pin.

And one property added rather than preserved: the double **counts
subscriptions** (`stdoutListens`, `stderrListens`), so acceptance criterion 4 —
exactly one stderr listener, on every path — becomes an assertion instead of a
claim. That invariant was the whole reason `_incumbentToken` could be deleted,
and nothing currently enforces it.

Migration is mechanical per file: delete the local double, import the helper,
construct the scenario. `_ExitedHandle` becomes `.refused(...)`,
`_SilentStreamHandle` / `_SilentHandle` / the five identical `_Handle`s become
`.armed()`, and `_DrivableStreamHandle` becomes `.armed()` driven through
`emitStdout` / `emitStderr`.

**Verify** — the whole watcher suite, since the point is that these files share
one definition now:

```sh
flutter analyze
flutter test test/watch_arm_signal_test.dart test/watch_shared_path_test.dart \
             test/watch_lease_release_test.dart test/watch_ceiling_derived_test.dart \
             test/watch_ceiling_per_host_test.dart test/watch_ceiling_recovery_test.dart \
             test/watch_diagnostics_both_backends_test.dart test/watch_lease_identity_test.dart \
             test/watch_transition_wiring_test.dart test/remote_watch_service_test.dart \
             test/watch_lease_teardown_exec_test.dart
flutter test
```

**Commit** (`git commit --no-edit`, code only).

### Phase 3 — prove the new checks can fail

3.1 New catalogue `tool/mutations/0044-arm-readiness.json`. Each entry names the
test file that must kill it:

| Mutation | Killed by |
| --- | --- |
| the marker is emitted **before** the lock prelude rather than after | 1.5 — a refusal would emit it |
| the marker is emitted before the lease-alive check | 1.7 / lease tests |
| the arm waits the ceiling instead of racing (`Future.any` → `exitCode` only) | *"settles on the marker, not the ceiling"* |
| any stderr line settles the arm, not only the marker | *"a lock refusal is still a refusal"* — `Setting up watches` would arm it |
| the readiness completer is completed unconditionally | *"a marker after the ceiling does not re-settle"* |
| the incumbent is captured but never reported | *"still names its incumbent"* |
| the ceiling returns `ready: true` on timeout | the backstop test's transition assertions |

3.2 Run this catalogue **and both existing watcher catalogues**, because this
work moves code they anchor to — `_incumbentToken` is deleted outright, and
0043's `p4: the refusal does not name its incumbent` anchors into it:

```sh
tool/mutate.py tool/mutations/0044-arm-readiness.json
tool/mutate.py tool/mutations/0043-one-watcher-per-repo.json
tool/mutate.py tool/mutations/0041-watcher-teardown.json
```

**A `DID NOT APPLY` is a failure of this phase, not a pass.** It means an anchor
no longer matches and the mutation silently tested nothing. Re-anchor it to the
equivalent line in the new code and re-run until every entry reports `KILLED`.
This has broken three times in this subsystem already (0043 deviation (c) and
(f)); assume it will break here.

3.3 Any mutation that **survives** is a real gap: write the missing test rather
than deleting the mutation. Any mutation that turns out to be a no-op — it
changes nothing observable — is a badly written mutation: fix the mutation, and
say so, the way 0043's sabotage round did.

**Commit** (`git commit --no-edit`, tests and catalogue).

### Phase 4 — measure it on the host, then close the record

4.1 Build and install: `./build_macos.sh --unsigned --install`.

4.2 With one remote tab connected, confirm from the host that exactly one
watcher holds the lock and that the marker is not visible anywhere it should not
be: the `.hb`/`.pid`/`mg-watch.lock` registry for the repo must show one token,
and `mg-watch: armed` must not appear in any file (it is a stderr line, never
written to disk).

4.3 **Measure the arm.** The diagnostics already record `armed` with a
timestamp; time from `watch()` to that record across five tab switches and
report the median. Acceptance: **median under 250 ms**, against the ~400 ms
0044 F7 measured. Report the actual number even if it misses — a measured miss
is a finding, not a failure to hide.

4.4 **Confirm the refusal still refuses**, which is the check that matters most:
this change must not be able to be described as having disabled the exclusion it
speeds up. From a second session (or a second app instance) arm the same
repository and confirm one honest `heldByAnother` naming the incumbent token,
and that the refused arm leaves no `.hb` behind.

4.5 Update `docs/0044-MADR-*.md` to `status: accepted`, `verified:` to the day,
and `docs/0044-PLAN-*.md` to `status: complete`, with the execution record: what
each phase did, the verification output rather than a summary of it, the
measured arm time, and a dated entry for every deviation.

4.6 Update the `docs/README.md` row.

**Commit** (`git commit --no-edit`, docs only — separate from every code
commit).

## Execution Record

### Phase 1 — the host scripts emit a readiness marker

Shipped 2026-09-10. `bounded_watch.dart` gained `watchArmedMarker`
(`mg-watch: armed`) and `_armedMarker()`; the marker is emitted from
`_leaseLoop` immediately after `{ $inner; } & w=$!` — which covers all three
leased forms at once, since `recursiveWatchScript` has no unleased branch — and
from the two `heartbeat == null` branches of the bounded builders.

Four executing tests, not the three planned. The fourth (*"a stale lease exits
before the marker"*) pins the one ordering the plan named but did not test: the
lease-alive check sits between the claim and the marker, so a stale lease exits
0 and emits nothing, and the client reads it exactly as it does today — a
watcher that armed and died.

```
flutter test test/watch_lease_teardown_exec_test.dart
00:10 +18: All tests passed!
flutter analyze
No issues found! (ran in 4.9s)
```

#### Deviation (a) — a pre-existing assertion matched the marker by prefix (2026-09-10)

`test/bounded_watch_test.dart:182` asserted
`expect(boundedInotifyScript(['/r/.git']), isNot(contains('mg-watch')))`. Step
1.3 adds the marker to that exact branch, so the script now contains
`echo 'mg-watch: armed' >&2` and the substring matched:

```
Expected: not contains 'mg-watch'
  Actual: 'set -- '/r/.git'; … || exit 97; echo 'mg-watch: armed' >&2; …'
```

Caused by this work, not pre-existing. The test's intent was "an unleased arm
references no lease-registry file"; `mg-watch` was standing in for the registry
filenames `mg-watch.<token>.pid` / `.hb`, and the marker shares the prefix
without sharing the meaning. Every other assertion in the suite uses
`mg-watch.` **with the dot** and was unaffected
(`bounded_watch_test.dart:164,175,189,235`, `remote_watch_service_test.dart:427`,
`watch_lease_release_test.dart:241,434`).

**Decision: option 1 — tighten the assertion to what it means.** It now names
the registry directly (`mg-watch.`, `.pid`, `.hb`) and is renamed *"no pid file
means no registry file is referenced"*. The rejected alternative was moving the
marker out of the two unleased branches, which would have kept the test file
untouched at the cost of making the marker a property of one call path rather
than of the script builders — production never takes those branches, but a
future caller of the unleased form would silently pay the full ceiling on every
arm with no test to say so. Deleting or loosening the assertion was not offered.

**Scope added to phase 1:** `test/bounded_watch_test.dart`.

#### Correction during phase 1

The plan's test 1.7 was written to assert `arms() == 1` outright once the marker
appeared. It read `0`. The marker is emitted after the watcher process is
**started**, not after it has run — which is precisely what the constant's
documentation claims and what makes the marker free (it never waits for the
inotify walk). The assertion became `settles(() => arms() == 1)` and the reason
is recorded in the test, because a reader would otherwise reasonably assume the
stronger guarantee.

### Phase 2 — the client races the marker against the exit status

Shipped 2026-09-10, in one commit with the doubles work deviation (b) added.

`remote_watch_service.dart`: `armSignalCeiling` (2 s) replaces the flat 250 ms;
the stderr listener moved above the race and took on the readiness marker and
the incumbent token alongside its existing diagnostics; the race is a
`Future.any` over `(exit, ready)`; `_incumbentToken` and its own 250 ms
`stderr.join()` are gone, `_lockHeldBy` stays. Both refusal branches cancel the
stderr subscription before the handle.

`test/helpers/fake_watcher_handle.dart` is new — one `FakeWatcherHandle` with
`armed()` / `refused()` / `silentHost()` — and eleven doubles across nine files
were deleted in its favour. `test/watch_arm_signal_test.dart` is new: nine
tests over the race, the ceiling, the refusals, and the one-listener invariant.

```
flutter analyze
No issues found!

flutter test <the ten watcher files>
00:14 +70: All tests passed!
```

#### Corrections during phase 2

**`MockStreamHandle` was wrongly in scope, and was reverted.** The plan listed
`test/helpers/mock_executor.dart` among the doubles to update, and it was —
until a check of its callers showed it is used by `glab_service_test.dart` and
`activity_command_executor_test.dart` and by **no watcher test at all**. Making
every mock stream announce a watcher readiness marker would have put a line on
`glab ci trace`'s stderr for no reason. It is out of scope; the plan's file list
was wrong a second time, in the opposite direction.

**The new test's settle signal was wrong, and every timing assertion passed for
the wrong reason.** The helper first waited on
`RemoteWatchService.liveWatchers` to become non-zero. A slot is reserved
**before** the stream is opened and given back if the arm fails, so that counter
reads 1 while the arm is still undecided: the headline assertion — a healthy arm
settles in under 250 ms — was satisfied in **0.3 ms**, having measured nothing.
Caught because the sibling assertions in the same helper (`stderrListens`, the
incumbent, the ceiling) failed loudly at the same time. The helper now waits on
the transition log for an `armed` or `armFailed` record, which is the arm's own
definition of settled. Worth recording as the instrument-verification rule
biting on the instrument itself: an assertion that cannot fail is not a check,
and a green one that runs in 0.3 ms is the shape that gives it away.

**`probe.ready` was dead, and is now the ceiling's only observability.** The
race returned a record whose `ready` field nothing read — a mutation aimed at it
would have survived by being a no-op. Rather than delete the field, the arm now
says so when it reaches the ceiling with neither signal:
`no readiness signal from the watcher on <repo> within 2000ms — arming anyway`.
That case was previously invisible: a host that never announces was
indistinguishable from a healthy one that announces in 50 ms, since both end up
armed. It is asserted in the silent-host test.

#### Deviation (b) — the plan undercounted the test doubles by seven, and the count was the symptom (2026-09-10)

Phase 2's client change landed analyzer-clean, and the three doubles the plan
named were updated to announce readiness. Their two files passed. Every
remaining failure was in a file whose double had not been touched:

```text
test/watch_shared_path_test.dart      PASS   (double updated)
test/watch_lease_release_test.dart    PASS   (double updated)
test/remote_watch_service_test.dart   6 failures
test/watch_ceiling_derived_test.dart  1 failure
```

Two failure shapes, one cause. Under `fake_async`, arms that used to settle
after 250 ms no longer settled at all, because the tests do not elapse as far as
`armSignalCeiling` (`Expected: eventDriven, Actual: polling`). In real time,
tests that push events after arming hung for the full 30 s test timeout, because
the stdout listener is attached only once the arm has committed.

**There are eleven doubles across ten files, not four**, and five of them are
byte-identical. The full census, the reason this is a finding rather than a
miscount, and the decision are recorded as **MADR amendment 0044.2**.

**Decision: option 2 — extract one shared double.** The rejected alternative was
option 1, the same one-line change applied to the seven remaining copies: it
would have gone green today and left eleven definitions of the arm protocol for
the next change to rediscover from its own failures — which is exactly how this
deviation was found. A third possibility, shortening `armSignalCeiling` so the
silent doubles pass unchanged, was not offered: it tunes a production constant to
accommodate fakes that misdescribe the host, and suppresses the signal that found
this.

**Scope added to phase 2** (new step 2.7, below): a new
`test/helpers/fake_watcher_handle.dart`, and migration of
`remote_watch_service_test.dart`, `watch_ceiling_derived_test.dart`,
`watch_ceiling_per_host_test.dart`, `watch_ceiling_recovery_test.dart`,
`watch_diagnostics_both_backends_test.dart`, `watch_lease_identity_test.dart`,
`watch_transition_wiring_test.dart`, `watch_shared_path_test.dart`,
`watch_lease_release_test.dart` and `test/helpers/mock_executor.dart`.

### Phase 3 — prove the new checks can fail

`tool/mutations/0044-arm-readiness.json`, ten entries: three against the
script's ordering, seven against the client's race.

```
tool/mutate.py tool/mutations/0044-arm-readiness.json
10 killed, 0 survived, 0 did not apply

tool/mutate.py tool/mutations/0043-one-watcher-per-repo.json
10 killed, 0 survived, 0 did not apply

tool/mutate.py tool/mutations/0041-watcher-teardown.json
27 killed, 0 survived, 0 did not apply
```

The kills that matter most are the two that would have shipped a working suite
over a broken feature: *"the marker is emitted before the lock prelude"* (a
refusal would announce itself, and the exclusion would silently stop working)
and *"the marker is treated as startup noise"* (nothing settles a healthy arm,
so every arm waits out the ceiling — a 2 s regression against the 250 ms this
work removes). Both are caught, the first by an executing test against a real
`sh`, the second by the timing bound.

#### Broken anchor (a) — `0043 p3` pointed at deleted code

`p3: a refused arm strands the lease it stamped` anchored on
`final incumbent = await _incumbentToken(handle);`, which phase 2 deleted. It
reported **0 matches**, i.e. it had silently stopped testing anything.
Re-anchored to the new refusal path (`errSub.cancel` / `handle.cancel` /
`releaseHostClaims`), and its `tests` list extended to
`watch_arm_signal_test.dart`, which now asserts the same release. **Fourth time
in this subsystem that running the catalogue at a boundary caught an inert
mutation** — 0043 deviations (c) and (f) are the others.

#### Broken anchor (b) — my own anchors, broken by `dart format`

`p2: the arm waits for the exit status alone` reported 0 matches on its first
run: the anchors were captured before the pre-commit `dart format`, which
rewrapped the `Future.any` expression across different lines. Re-anchored
against the formatted source, and every entry re-verified to match exactly once
before re-running. **Build the catalogue after formatting, not before.**

#### A false survivor, and what caused it (2026-09-10)

The first combined run reported **2 survived** in the 0043 catalogue — *"the
watcher is built eagerly"* and *"a new arm does not wait for a pending
teardown"*. Both were treated as real gaps and investigated rather than
retried.

The first was reproduced by hand: a scratch `git worktree` at the committed
tree, the mutation applied to the copy, one test run.

```
Expected: empty
  Actual: ['hm5xykj9hd0']
building on first listen, not on the call, is what keeps an unused stream free
```

The mutation **is** caught. Re-running the whole 0043 catalogue on an idle
machine gave `10 killed, 0 survived, 0 did not apply`.

The cause is worth recording, because it is a property of this suite rather
than of this change: both suspect tests assert on **real-time** delays —
`settleArm()`'s 500 ms, and a 400 ms teardown observed inside a 2 s window —
and three catalogues had been run back to back, each running test files of its
own. Under that load the windows shift and the assertions flip.

**A false survivor is more dangerous than a false kill.** A false kill looks
like a pass and is invisible; a false survivor sends the next person hunting a
gap that does not exist, and the honest response to it — write the missing test
— would have added a test for behaviour that was already covered. **Run the
catalogues one at a time, with nothing else running**, and reproduce any
survivor by hand in a scratch worktree before believing it.

### Phase 4 — measure it on the host

**Partial.** The build, the entitlements invariant and the host-side measurement
are done; the three checks that need a running build and a person driving it are
not, and are listed at the end as what is still owed.

#### Built and installed

```
./build_macos.sh --unsigned --install
CFBundleShortVersionString  1.6.3.14
git describe                v1.6.3-14-g3831851
```

The stamped version is this work's HEAD, so the installed bundle is the tree
these measurements describe. `git status --porcelain macos/` was polled every
30 s for the whole build and stayed **empty** — MADR 0042's invariant holding
live, a year of `Release.entitlements` churn ago.

#### What the readiness marker costs on the real host

The decisive number, since the whole change is "replace a 250 ms wait with a
signal": **how long after the channel opens does the marker arrive?**

Measured by running the production script — generated by `remoteWatcherArgs`
itself, not retyped — against a scratch repository on the reporting host, over
a multiplexed connection so each sample reuses an established one:

```text
control (a bare echo on stderr):  median 234.2 ms   min 223.2
the real arming script:           median 242.9 ms   min 228.8
what the script costs before it announces:  +8.7 ms
the fixed wait this replaces:              250.0 ms
```

**The marker costs ~9 ms of host-side work and no extra round trip.** It is not
"one more round trip" as the MADR's arithmetic assumed — the script takes its
lock, records its pid, checks its lease and forks the watcher in under 10 ms,
and announces on a channel that is already open. Against 250 ms paid by every
arm that succeeded, that is the whole of the win.

The absolute figures are **not** comparable to MADR 0044 F7's 49.4 ms round
trip and should not be read as a regression in the path. They include an
OpenSSH client spawn and channel open that dartssh2 does not pay, and the path
itself moved during the session: the same control command measured **8.5 ms**
in one pass and **234 ms** twenty minutes later. Only the interleaved
difference is meaningful, which is why the probe alternates control and arm
samples rather than running two loops.

#### Two measurement errors, both mine, both corrected

**Two loops minutes apart are not comparable on this path.** The first probe
timed the control in one loop and the arm in another and read a **+223.7 ms**
difference — which would have said the marker cost as much as the wait it
replaces. Re-running the control alone gave 8 ms for the same command. The
probe now interleaves them; the corrected answer is +8.7 ms.

**`for line in proc.stderr` reads ahead.** Iterating a text file object in
Python buffers in chunks, so the first line does not arrive when it is written.
A control using `readline()` and an arm using `for line in` were being compared
directly. Both use `readline()` now. This one turned out not to explain the
gap, but it was a real defect in the instrument and it is recorded because the
next person writing a first-byte probe will reach for the iterator.

#### 4.2 — the registry census, with the new build live

With one remote tab active, the host carries exactly one of everything, all
under one token:

```text
watcher processes carrying the readiness marker:  6   (2 watchers x 3 lines, mid-switch)
settled state, one active remote tab:             1 watcher, 1 lock, 1 pid, 1 heartbeat
stranded .hb with no pid beside it:               0
```

Single-active-mount again, and the registry exactly consistent — no leaked
slot, no leaked process, nothing to reclaim. MADR 0044 F11's stranded heartbeat
did not recur.

#### 4.4(a) — a genuinely foreign session is refused by the host lock

The script was generated by `remoteWatcherArgs` itself and armed from a second
SSH session against the repository the app was watching:

```text
exit code: 98
stdout:    ''
stderr:    mg-watch: lock held by <incumbent-token>
```

`98` is `boundedWatchLockedExit`; the incumbent is named; and **no readiness
marker was emitted**. That last part is the ordering the whole design rests on,
observed against a real shell rather than argued: a refusal exits before the
marker, so it cannot announce itself, so the client's race is well-ordered. The
incumbent's lock, pid file and heartbeat were untouched, and the refused arm
left nothing behind.

#### 4.4(b) — the client refuses honestly, and cheaply

The check that mattered most: this change must not be describable as having
disabled the exclusion it speeds up. A foreign lock was staged on a second
repository, then that repository's tab was opened. The app's output log:

```text
watcher: mg-watch: lock held by <foreign-token>
watcher: another live watcher already holds <repo> (token <foreign-token>) — polling here
watcher: polling <repo> — arm unavailable: heldByAnother; watchers held 0, restarts spent 0
```

**`restarts spent 0`** and **`watchers held 0`**: the refusal degraded straight
to polling without spending the restart budget on doomed retries (0022 M6) and
gave its slot back. The host showed **no stranded heartbeat** — MADR 0043 phase
3's refusal cleanup, confirmed on a live host for the first time; MADR 0043's
own record could only unit-test it.

The status-bar watch-health dot went orange (polling) and stayed orange,
sampled once a second for 50 s.

#### And the recovery after the incumbent leaves

Not planned, taken because the opportunity was there. With the foreign lock
removed, the repository re-armed on its own recovery timer with a **new token**
inside roughly two minutes — comfortably within the three-minute
`recoveryInterval`:

```text
10:40:27  RE-ARMED: <new-token>  <repo>
```

So the full cycle is confirmed live: armed -> refused by a foreign holder ->
polling -> holder leaves -> armed again.

#### An unrelated defect this surfaced (2026-09-10)

Forcing a repository into polling made a pre-existing UI bug visible, and it is
recorded here because that is where the evidence is, not because it belongs to
this work. The maintainer reported the tab's dirty dot "blinking every few
seconds". Sampled once a second:

```text
status bar   -> ORANGE            (steady — correct, the repo is polling)
tab chip     -> ORANGE
tab chip     -> none(21,40,57)    (the tab's background: the dot is gone)
tab chip     -> ORANGE
```

Two widgets read the same provider through different accessors:

```dart
// tab_strip.dart:178             — null while a refetch is in flight
ref.watch(statusProvider(repoPath)).asData?.value

// current_repo_indicator.dart:26 — keeps the last value across a refetch
ref.watch(statusProvider(repoPath)).value
```

`asData` is null whenever the `AsyncValue` is `AsyncLoading`, **even when it
still carries the previous data**. So the tab's dot blanks for the duration of
every status refetch. It is only conspicuous on a polling repository, which
refetches on a timer rather than when something actually changes — which is why
deliberately refusing an arm is what exposed it.

Not caused by this work: `tab_strip.dart` appears in none of its commits. Not
fixed here either, because it is outside the approved scope. Note that
`asData?.value` is deliberate elsewhere — `namespace_field.dart` documents
"never a spinner, never an error" for it — so the fix is the right accessor at
this one call site, not a blanket rule.

#### Still owed

#### Still owed — 4.3


~~The installed bundle is not the running one: a census of the host shows zero
watcher processes whose script contains `mg-watch: armed`.~~ Resolved — the app
was restarted, and every watcher on the host now carries the marker. What
remains:

* **the arm's end-to-end cost across tab switches** (acceptance criterion 6).
  The host-side component is measured above at **+8.7 ms**, and the tab-switch
  transition itself — one repository's watcher torn down, the next armed — is
  still unobserved, which MADR 0044 already names as a limit of its own
  measurements.

## Verification

Gate for the whole plan:

```sh
flutter analyze                                   # 0 issues
flutter test                                      # all pass, no new skips
tool/mutate.py tool/mutations/0044-arm-readiness.json
tool/mutate.py tool/mutations/0043-one-watcher-per-repo.json
tool/mutate.py tool/mutations/0041-watcher-teardown.json
```

Every catalogue must report `N killed, 0 survived, 0 did not apply`.

Per the pre-commit rule, `flutter analyze` and `dart format --output=none
--set-exit-if-changed` run against every staged Dart file before each phase
commit, and the gate's exit status is captured rather than piped into a filter.

## Acceptance Criteria

1. A healthy arm settles on `watchArmedMarker`, not on a timer, and no test
   waits `armSignalCeiling` except the one that exists to prove the backstop.
2. `boundedWatchLockedExit` still yields `WatchUnavailableReason.heldByAnother`,
   still names the incumbent token, still releases the stamped lease, and still
   does not spend the restart budget.
3. `boundedWatchNoPathsExit` still yields `WatchUnavailableReason.noWatchedPaths`
   with the same guarantees.
4. Exactly one stderr listener exists on the watcher handle, for the life of the
   arm, on every path — **asserted**, via the shared double's subscription
   counters, not claimed.
5. `_incumbentToken` and both 250 ms timeouts are gone from the arm path.
6. Measured on the host: median arm under 250 ms across five tab switches.
7. Three mutation catalogues green, with no `DID NOT APPLY`.
8. Exactly one watcher-channel double exists.
   `grep -rn 'implements SSHStreamHandle\|implements CommandStreamHandle' test/`
   names `FakeWatcherHandle` and nothing else under `test/watch*`. The other
   doubles it lists belong to other subsystems — clone, CI trace, and the
   general-purpose `MockStreamHandle` — and are out of scope; the criterion is
   one double for the ARM PROTOCOL, not one for every stream in the suite.
9. The MADR carries amendments 0044.1 and 0044.2; this plan carries an execution
   record and a dated entry for every deviation.

## Rollout and Rollback

Four commits, one per phase, code and docs never mixed. Nothing is pushed unless
asked for in the same turn.

**Rollback is a revert of phases 1–2 together**, not either alone: phase 2's
client waits for a marker only phase 1 emits, so a client newer than its script
would wait out `armSignalCeiling` on every arm — 2 s instead of 250 ms, eight
times worse than what this replaces. There is no version skew in practice, since
the client generates the script it runs, but the coupling is the reason the two
phases revert as a pair.

The shared double added by deviation (b) is test-only: it ships in no build,
and it reverts with phase 2 because it encodes phase 2's arm protocol.

**No host state changes shape.** The registry files, the lock directory, the
lease semantics and the exit codes are all untouched; the marker is a line on a
channel that is already read. A host that somehow does not emit it degrades to
the ceiling, which is the old behaviour with a longer clock — slower, never
wrong.

## Risks

* **The shell may buffer the marker.** POSIX leaves stderr unbuffered and both
  `dash` and `bash` write `echo >&2` straight through, but this is asserted
  rather than measured until phase 1.7 runs it against a real `sh`. If it does
  not arrive promptly, the fix is the signal's placement, not a longer ceiling.
* **The marker says "the watcher process was started", not "watches are
  established".** That is exactly what the 250 ms wait established too — it only
  ever proved "no refusal within 250 ms" — so this is not a regression, and it
  is stated here so nobody later reads it as a stronger guarantee than it is.
  `inotifywait` does print `Watches established.` and
  `_isWatcherStartupNoise` already recognises it; it was rejected as the
  mechanism because `fswatch` has no equivalent, which would leave macOS hosts
  on the ceiling.
* **A watcher that dies immediately after arming** is unchanged: `onDone` files
  a `stopped` transition and `scheduleRestart` runs, as today.
* **The fakes could lie.** Four test doubles now assert an ordering that
  production gets from dartssh2's queuing and they get from `onListen`. This is
  called out in 2.6 because a fake that emits the marker too early would make
  every test pass and prove nothing about the race.
