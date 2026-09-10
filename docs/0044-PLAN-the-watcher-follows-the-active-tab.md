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
* The four test doubles that stand in for a live watcher, plus new tests.
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
   arm, on every path.
5. `_incumbentToken` and both 250 ms timeouts are gone from the arm path.
6. Measured on the host: median arm under 250 ms across five tab switches.
7. Three mutation catalogues green, with no `DID NOT APPLY`.
8. The MADR carries amendment 0044.1; this plan carries an execution record and
   a dated entry for every deviation.

## Rollout and Rollback

Four commits, one per phase, code and docs never mixed. Nothing is pushed unless
asked for in the same turn.

**Rollback is a revert of phases 1–2 together**, not either alone: phase 2's
client waits for a marker only phase 1 emits, so a client newer than its script
would wait out `armSignalCeiling` on every arm — 2 s instead of 250 ms, eight
times worse than what this replaces. There is no version skew in practice, since
the client generates the script it runs, but the coupling is the reason the two
phases revert as a pair.

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
