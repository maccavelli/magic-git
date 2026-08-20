---
status: "executed"
date: 2026-08-18
associated-madr: "0011-MADR-ssh-transport-stability-hardening.md"
owner: [Maintainer]
target-milestone: Next work cycle (post-review)
verified: 2026-08-20
---

# Plan: Harden the SSH transport against false-positive session kills during fetch/pull/push

## Executive Summary & Goal

Companion to
[0011-MADR-ssh-transport-stability-hardening.md](./0011-MADR-ssh-transport-stability-hardening.md).

**Problem.** `fetch`/`pull`/`push` over SSH intermittently kill the session and
force a reconnect. Root cause (code-verified): `ConnectionHealthMonitor`
(`lib/core/ssh/ssh_client_manager.dart:48-112`) is activity-blind — it pings
every 15 s, times out each ping at 15 s, and force-closes **both** SSH clients
after 3 consecutive failures (~45–60 s of unanswered pings), regardless of
whether the connection is actively streaming pack data. During network ops the
command client multiplexes up to 4 concurrent compressed reads, one sync-lane
fetch/push, and the pings over a single TCP connection; on a saturated or
high-RTT link, ping replies queue behind bulk channel data and starve past
15 s. Compounding factor (library-verified, dartssh2 2.22.5): server-initiated
rekey (OpenSSH `RekeyLimit` default 1 GB / 1 h — routinely crossed mid-fetch/
mid-push) buffers every non-KEX outgoing packet, including pings, in an
unbounded list until `NEW_KEYS`
(`ssh_transport.dart:247,260-263,1404-1409`; bypass only for message IDs
20–49 and ≤ 4 — `SSH_MSG_GLOBAL_REQUEST` is 80).

**Goal.** Make liveness probing activity-aware so a busy connection is never
killed by the monitor (the in-flight command's own outcome is the liveness
signal while busy), keep idle dead-peer detection exactly as fast as today
(15 s/15 s/3 ≈ 45–60 s), and ship drop-cause telemetry that proves the fix
and catches regressions.

**Acceptance criteria.**

1. A connection carrying an in-flight command or streaming bytes can never be
   declared dead by the health monitor (unit-proven).
2. An idle connection with a dead peer is still killed after exactly 3
   consecutive failed pings, within the existing ~45–60 s window
   (unit-proven; existing behavior pinned).
3. Every unexpected drop records a cause-attributed sample
   (`monitor` / `transportError` / `remoteClosed`) visible on the Dashboard;
   user-initiated disconnects record nothing.
4. A bulk transfer over a real sshd completes with zero monitor kills and the
   session still serves commands afterwards (live integration test).
5. `flutter analyze` and `flutter test` clean; all pre-existing transport
   hardening tests pass unchanged in intent (constructor additions are
   backward-compatible).

**Non-goals** (per MADR): RTT-adaptive probe budgets (deferred refinement),
auto-resume of failed network ops, dartssh2 fork/patch, changes to
`LocalCommandExecutor` / `ProxyCommandExecutor` (no monitors exist there).

## Prerequisites & Dependencies

- **Toolchain**: current Flutter SDK per `pubspec.yaml`; repo commands are
  `flutter pub get`, `flutter analyze`, `flutter test` (see `AGENTS.md`).
- **Library**: `dartssh2: ^2.22.5` (locked: 2.22.5). Pinned 2026-08-18 (bumped
  from `^2.22.0`/2.22.2) — a drop-in 2.x bump; no API change. All facts below
  verified against the locked 2.22.5 source in the pub cache. **Deferred to a
  separate decision**: the 3.x line (latest 3.3.0) — a breaking change
  (`SSHClient.close()` → `Future<void>`, `identities` type change) published
  under a new maintainer (`github.com/vicajilau/dartssh2`, pub.dev verified
  publisher `victorcarreras.dev`; formerly TerminalStudio). Its
  `SSHDisconnectError` and hang-forever fixes (#212/#210) are directly
  relevant to this plan's drop-cause telemetry and should be evaluated as a
  follow-up, not folded in here.
- **No new packages.** All changes use existing deps
  (`flutter_riverpod 3.x`, `macos_ui`, dart core).
- **Test infra already in place**:
  - `test/ssh_transport_hardening_test.dart` — fake `ServerSocket` servers;
    `ConnectionHealthMonitor` is fully injectable (constructor takes `ping`,
    `interval`, `pingTimeout`, `failureThreshold`), so starvation scenarios
    are testable with millisecond timers and fake pings.
  - `test/ssh_live_transport_test.dart` — `_DisposableSshd` spins a real
    loopback sshd (`integration` tag; self-skips when `/usr/sbin/sshd` is
    absent).
- **Repo constraints**: new code must be analyzer-clean on first pass
  (strict-casts/inference, `unawaited_futures`, `prefer_final_locals`,
  `prefer_const_constructors`); no comments policy exception — this codebase
  is comment-heavy by design, match the surrounding style; never commit unless
  asked; commit only via `git commit --no-edit`.

## Architecture & Technical Design Summary

### Change map (files → modifications)

| File | Change |
|---|---|
| `lib/core/exec/command_telemetry.dart` | Add `TransportDropCause`, `TransportDropSample`, ring + counters + `recordTransportDrop` |
| `lib/core/ssh/ssh_client_manager.dart` | Monitor gains `isBusy` + `resetFailures()`; manager gains busy-probe registry, settle/activity notifications, `lastDropCause`, `_connectedAt`, drop recording in both `onDead` closures |
| `lib/core/ssh/ssh_command_executor.dart` | Busy accounting (`transportBusy`, `streamBusy`, settle + stream-byte notifications); register probes with the manager in the constructor |
| `lib/core/providers/app_providers.dart` | `_watchForDrop`/`_onTransportClosed` split normal vs error completion; cause recording with monitor dedup |
| `lib/features/dashboard/dashboard_sheet.dart` | Connection-health row: last drop cause/age, monitor-kill count |
| `test/ssh_transport_hardening_test.dart` | New monitor unit group (busy-skip, threshold pin, reset, transition) + telemetry tests |
| `test/ssh_live_transport_test.dart` | Busy accounting over real sshd; bulk-transfer regression test |
| `docs/ARCHITECTURE_PLAN.md` | §0.1: busy-aware monitoring description + remote-host recommendations subsection |

### Component design

#### 1. `ConnectionHealthMonitor` — activity-aware probing

New optional constructor param and method; existing params and defaults
(15 s / 15 s / 3) unchanged:

```dart
ConnectionHealthMonitor({
  required this.ping,
  required this.onDead,
  this.onPingSample,
  this.interval = const Duration(seconds: 15),
  this.pingTimeout = const Duration(seconds: 15),
  this.failureThreshold = 3,
  this.isBusy,            // NEW — null => probe always (today's behavior)
});

final bool Function()? isBusy;   // NEW

/// NEW — clears accumulated failures (called on transport activity).
void resetFailures() {
  _failures = 0;
}
```

`_probe()` rules (deterministic, in order):

1. Existing guards first: `if (_probeInFlight || _stopped) return;`
2. **Busy check at tick**: `if ((isBusy?.call() ?? false)) { _failures = 0; return; }`
   — skip the probe and clear stale failures, so an idle-blip count can never
   carry into a busy period and kill later.
3. Probe as today. On failure, **re-check busy before counting**:
   a probe that started idle and timed out after a transfer began must not
   count — `catch (_) { if (_stopped) return; if (isBusy?.call() ?? false) return; if (++_failures >= failureThreshold) { stop(); onDead(); } }`.
4. Success path unchanged (`_failures = 0; onPingSample`).

Rationale while busy: death is detected by the work itself — the command's own
timeout (`SSHCommandExecutor.defaultTimeout` 60 s; `GitService.networkTimeout`
3 min at `git_service.dart:1059`, applied to fetch/pull/push) and the
existing `_watchForDrop` listener on `SSHClient.done` (which already catches
error-completed drops, `app_providers.dart:1913-1923`).

#### 2. `SSHCommandExecutor` — busy accounting

All request/response traffic funnels through `_run` (`ssh_command_executor.dart:579`),
and streams through `executeStream` + `_SshSessionStreamHandle`, so accounting
at those two seams covers `execute`, `uploadBytes` (sideloads on slow
air-gapped links included), watchers, and CI traces.

```dart
// Request/response busy — incremented at the top of _run's body,
// decremented in its finally (every settle path: success, timeout,
// SSHOutputExceeded, superseded, transport error, retry attempts —
// each attempt is a balanced increment/decrement; the retry backoff
// between enqueues is correctly NOT busy).
int _activeCommands = 0;
bool get transportBusy => _activeCommands > 0;

// Stream busy — a stream is "busy" only while bytes are actually flowing.
// A watcher can be legitimately quiet for hours; probing it then is exactly
// the NAT-keepalive + dead-peer detection it exists for.
int _activeStreams = 0;
DateTime? _lastStreamByteAt;
static const Duration streamBusyWindow = Duration(seconds: 30);
bool get streamBusy =>
    _activeStreams > 0 &&
    _lastStreamByteAt != null &&
    DateTime.now().difference(_lastStreamByteAt!) < streamBusyWindow;
```

Settle notifications (in the same `finally` that decrements
`_activeCommands`): `_clientManager.noteCommandSettled();` — any command
settling proves the command client was alive; clears accumulated monitor
failures. Stream bytes: `_SshSessionStreamHandle.stdout`/`stderr` maps update
`_lastStreamByteAt` and call `_clientManager.noteStreamActivity()` (throttled
to at most once per second by a simple timestamp comparison — the notification
only resets a counter, so coalescing is safe). Stream count decrements in the
existing `_noteClosed` path (`ssh_command_executor.dart:133-137`), which
already fires for both natural death and `cancel()` — via an `onClosed`
callback passed to the handle constructor.

Registration (deterministic wiring, in `SSHCommandExecutor`'s constructor,
which already receives the manager):

```dart
SSHCommandExecutor(this._clientManager) {
  _clientManager.registerBusyProbes(
    command: () => transportBusy,
    stream: () => streamBusy,
  );
  _scheduler.setMaxConcurrentReads(_adaptiveReads.effectiveCap);
}
```

#### 3. `SSHClientManager` — probe registry, cause attribution, drop recording

```dart
bool Function()? _commandBusyProbe;   // NEW
bool Function()? _streamBusyProbe;    // NEW
TransportDropCause? _lastDropCause;   // NEW
DateTime? _connectedAt;               // NEW — set when a client attaches

TransportDropCause? get lastDropCause => _lastDropCause;  // NEW

void registerBusyProbes({                 // NEW
  bool Function()? command,
  bool Function()? stream,
}) {
  _commandBusyProbe = command;
  _streamBusyProbe = stream;
}

void noteCommandSettled() => _health?.resetFailures();      // NEW
void noteStreamActivity() => _streamHealth?.resetFailures(); // NEW
```

Monitor construction sites (both must receive their probe):

- `connect()` (`ssh_client_manager.dart:345-356`): command monitor gets
  `isBusy: _commandBusyProbe`. Its `onDead` closure gains, **before** closing
  clients:
  ```dart
  _lastDropCause = TransportDropCause.monitor;
  CommandTelemetry.instance.recordTransportDrop(TransportDropSample(
    cause: TransportDropCause.monitor,
    failures: monitor.failures,
    busy: _commandBusyProbe?.call() ?? false,
    connectionAge: DateTime.now().difference(_connectedAt ?? DateTime.now()),
    at: DateTime.now(),
  ));
  ```
  (`monitor` is the just-constructed local; `failures` getter already exists
  at `ssh_client_manager.dart:80`.)
- `_attachStreamClient()` (`:382-404`): stream monitor gets
  `isBusy: _streamBusyProbe`; its `onDead` records the same sample shape with
  `busy: _streamBusyProbe?.call() ?? false`.

`_connectedAt` is set where `_client` is attached in `connect()`
(`:330-332`). `disconnect()` and `_closeClient()` reset
`_lastDropCause = null` and `_connectedAt = null` so attribution never leaks
across sessions. Stream redial (`_onStreamClientLost`, `:412-464`) needs no
probe plumbing beyond `_attachStreamClient` receiving the stored probe.

#### 4. `CommandTelemetry` — drop-cause samples

```dart
enum TransportDropCause { monitor, transportError, remoteClosed }

@immutable
class TransportDropSample {
  final TransportDropCause cause;
  final int failures;         // unanswered pings at death (monitor only; else 0)
  final bool busy;            // probe state at death
  final Duration connectionAge;
  final DateTime at;
  const TransportDropSample({...});
}
```

On `CommandTelemetry`: bounded ring of the last 20 drops
(`_dropRingCapacity = 20`), `recordTransportDrop(sample)` (with
`notifyListeners()`), `List<TransportDropSample> get drops`,
`int get monitorKillCount`. **Deliberate deviation**: `reset()` does *not*
clear drops — they describe session history and must survive the reconnect
that follows them so the Dashboard can answer "why did it just drop" while
`lost`/`reconnecting`. Documented in the member doc.

#### 5. `ConnectionController` — cause recording with monitor dedup

`_watchForDrop` (`app_providers.dart:1913-1923`) currently merges normal and
error completions. Split them:

```dart
done
    .then((_) => _onTransportClosed(attempt, transportError: false))
    .catchError((Object _) => _onTransportClosed(attempt, transportError: true));
```

`_onTransportClosed(attempt, {required bool transportError})` — after the
existing `state.phase != connected` guard (which already excludes
user-initiated disconnects) and before setting `lost`:

```dart
final manager = ref.read(sshClientManagerProvider);
if (manager.lastDropCause == null) {
  CommandTelemetry.instance.recordTransportDrop(TransportDropSample(
    cause: transportError
        ? TransportDropCause.transportError
        : TransportDropCause.remoteClosed,
    failures: 0,
    busy: ref.read(executorProvider).transportBusy,
    connectionAge: Duration.zero,
    at: DateTime.now(),
  ));
}
```

Dedup rule: a monitor kill already recorded in the manager's `onDead`
(`lastDropCause == monitor`) must not be double-counted when `done` completes
and this path fires. Everything else (state transition, `_autoReconnect`)
unchanged.

#### 6. Dashboard surfacing

`_commandsSection` in `lib/features/dashboard/dashboard_sheet.dart:551-596`
already listens to `CommandTelemetry.instance`. Add one row beneath the
existing stats when `t.drops.isNotEmpty`: latest drop's cause, age
("3 min ago"), `failures` for monitor cause, `busy` flag; plus a
`monitorKillCount` stat. Target: 0 monitor kills in a healthy session — this
row is the fix's tripwire.

### Behavior matrix (deterministic expectations)

| State | Probe? | Death detection path |
|---|---|---|
| Idle, healthy | every 15 s | — |
| Idle, dead peer | every 15 s | monitor kills after 3 failures (~45–60 s) → `done` → auto-reconnect (unchanged) |
| Busy (command in flight), healthy | skipped; failures held at 0 | — |
| Busy, dead peer (RST/error) | skipped | socket error completes `done` → `transportError` recorded → auto-reconnect |
| Busy, blackhole peer (no RST) | skipped | command's own timeout (≤ 3 min network ops) fails it; probes resume on next idle tick and kill within ~45–60 s |
| Stream bytes flowing (CI trace) | skipped on stream monitor; failures reset | trace's own failure/exit handling (unchanged) |
| Stream quiet (watcher, no events) | every 15 s | monitor kills after 3 failures → redial cycle (unchanged) |

## Phased Execution Plan

### Phase 1 — Drop-cause telemetry foundation (measure first)

Ship attribution before behavior changes so the very next real-world
disconnect is diagnosable.

1. `command_telemetry.dart`: add `TransportDropCause`, `TransportDropSample`,
   `_dropRing` (cap 20), `recordTransportDrop`, `drops`, `monitorKillCount`;
   leave `reset()` untouched for drops (document why).
2. `ssh_client_manager.dart`: add `_connectedAt`, `_lastDropCause` + getter;
   record the monitor sample in both `onDead` closures; clear both in
   `disconnect()`/`_closeClient()`.
3. `app_providers.dart`: split `_watchForDrop` completions; record
   `transportError`/`remoteClosed` in `_onTransportClosed` with the dedup
   check.
4. `dashboard_sheet.dart`: last-drop row + monitor-kill stat.
5. Tests: telemetry ring/counter semantics (unit); manager records `monitor`
   cause on forced death and clears it on disconnect (extend
   `ssh_transport_hardening_test.dart`).

### Phase 2 — Activity-aware monitoring (the fix)

1. `ssh_client_manager.dart`: `ConnectionHealthMonitor.isBusy` +
   `resetFailures()` with the `_probe()` rules above; manager
   `registerBusyProbes`/`noteCommandSettled`/`noteStreamActivity`; wire
   probes into both monitor construction sites.
2. `ssh_command_executor.dart`: busy accounting in `_run` (balanced
   increment/decrement + settle notification in `finally`); stream accounting
   (count via `onClosed` callback from `_noteClosed`; byte latch via
   stdout/stderr maps, 1 s-coalesced `noteStreamActivity`); `transportBusy`/
   `streamBusy` getters; constructor registration.
3. Tests (unit, millisecond timers — monitor is fully injectable):
   - `busy connection: probes skipped, failures never reach threshold` —
     fake ping always throws, `isBusy: () => true`, run ≥ 10 intervals,
     assert no `onDead`, `failures == 0`.
   - `idle connection dies at exactly failureThreshold failures` — pin
     existing behavior: with `isBusy: () => false`, `onDead` fires after the
     3rd failure and not before.
   - `busy→idle transition resumes probing and kills a dead peer`.
   - `failure during a probe that crossed into busy does not count`.
   - `resetFailures clears accumulated failures` — 2 failures, reset, 2 more
     failures → alive; 3rd after reset → dead.
   - `stale failures clear when the connection goes busy`.

### Phase 3 — Regression, live verification, soak

1. `ssh_live_transport_test.dart` additions (all `integration`-tagged,
   self-skipping without sshd):
   - `transportBusy is true while a command runs and settles back to false` —
     start `sleep 2` on the read lane, poll the getter, assert true during /
     false after, and `manager.client` still live (no monitor kill).
   - `bulk transfer completes with the health monitor armed` — stream a
     ≥ 100 MB payload (e.g. `cat` of a seeded file, or `dd if=/dev/zero`
     through `executeStream`) while pings run; assert zero `monitor` drops in
     `CommandTelemetry.instance.drops` and a follow-up `echo` succeeds.
2. Run the full suite: `flutter analyze`, then `flutter test` (includes
   `integration`-tagged tests; takes minutes — expected).
3. Manual soak (documented procedure, run before declaring done): connect to
   a real remote over a throttled link (Network Link Conditioner, 1–3 Mbps
   high-latency profile); run repeated fetch/pull/push of a repo with a
   ≥ 500 MB pack for 30+ minutes; acceptance: zero unexpected disconnects,
   zero `monitor`-cause drops on the Dashboard; any residual drop must be
   `transportError`/`remoteClosed` and gets investigated separately.

### Phase 4 — Docs, guidance, upstream

1. `docs/ARCHITECTURE_PLAN.md` §0.1: document busy-aware monitoring (replace
   the implicit "monitor pings every 15 s" description), the drop-cause
   telemetry, and note that rekey-window tolerance falls out of busy-pause.
2. Same §0.1, new short subsection "Remote host recommendations": keep
   `ClientAliveInterval` ≤ 60 s with `ClientAliveCountMax` ≥ 3; leave
   `RekeyLimit` at default or higher (smaller limits multiply mid-transfer
   rekey stalls); expect NAT/LB idle timeouts (AWS NLB 350 s, corporate
   firewalls 60–300 s) — client probing at 15 s covers them.
3. File two upstream issues on `vicajilau/dartssh2`:
   - bound `_rekeyPendingPackets` (a stalled rekey buffers forever —
     acknowledged by PR #125's author; suggest size/time limit + fail the
     connection instead of wedging);
   - expose OS-level TCP keepalive (e.g. `SocketOption.tcpKeepAlive`) through
     `SSHSocket.connect` (verified absent in 2.22.5: the factory accepts only
     `timeout`).
4. If the soak in Phase 3 still shows starvation complaints on idle-but-slow
   links, schedule the MADR's deferred refinement (RTT-adaptive probe budget
   reusing `onPingSample` RTTs) as a follow-up decision — not in this plan.

## Verification & Testing Strategy

- **Unit (deterministic, no network)** — new groups in
  `test/ssh_transport_hardening_test.dart`: the six monitor tests above,
  telemetry drop-ring tests, manager cause-attribution tests. All use
  millisecond `interval`/`pingTimeout` values via the monitor's existing
  constructor injection; no sleeps longer than ~1 s total.
- **Live integration** — `test/ssh_live_transport_test.dart` (real disposable
  sshd): busy accounting lifecycle and bulk-transfer regression (Phase 3).
  These prove the full stack (executor accounting → manager probe → monitor
  skip) end-to-end.
- **Regression pin** — existing tests pass unchanged: parallel-handshake
  connect, verifier serialization, disconnect force-close, redial backoff
  schedule, upload timeout scaling (`ssh_transport_hardening_test.dart`);
  malformed UTF-8, timeout-kill, compressed read, in-flight disconnect
  supersession, executor-seam parity (`ssh_live_transport_test.dart`).
- **Static** — `flutter analyze` clean under the repo's strict lints.
- **Full suite** — `flutter test` (minutes; includes integration tags).
- **Manual soak** — throttled-link fetch/pull/push loop per Phase 3 step 3,
  with the Dashboard drop row as the oracle.

## Rollback & Mitigation Procedures

**Rollback is trivial by construction.** Every new member is additive and
optional: `isBusy == null` reproduces today's probe-always behavior;
`registerBusyProbes` never called → probes null → unchanged; telemetry adds
fields the Dashboard renders only when present; no persisted state, no
settings migration, no wire-format change. To revert: `git revert` the plan's
commit range and rebuild — nothing else to undo.

**Risk mitigations:**

| Risk | Mitigation |
|---|---|
| Busy accounting leaks (counter never decrements) → probes permanently suspended → idle drops undetected | Balanced `try/finally` in `_run`; decrement in the single `_noteClosed` path; unit tests for every settle branch (success, `SSHCommandTimeout`, `SSHOutputExceeded`, `SSHCommandSuperseded`, transport error); live test asserts `transportBusy == false` after each command |
| Dead-while-busy detection delayed (up to command timeout on blackhole links) | Socket errors still complete `done` immediately (existing `_watchForDrop` catches both completions); a killed connection would have failed the command anyway — user-visible cost identical, false-kill cost removed |
| Double-counting a monitor kill when `done` completes after `onDead` | `lastDropCause` dedup check in `_onTransportClosed`; cleared on `disconnect()`/`_closeClient()` |
| Stream monitor over-eager skip (watcher wrongly "busy") | `streamBusy` requires bytes within the last 30 s; a quiet watcher fails that and keeps probing (its NAT-keepalive job) |
| Probe in flight when the connection turns busy | Failure accounting re-checks `isBusy` before incrementing — a probe started idle that times out during a transfer never counts |
| Redial-attached stream monitor missing its probe | `_attachStreamClient` reads the stored `_streamBusyProbe` field; covered by Phase 2 tests via the manager API |
| Drops cleared by `reset()` on reconnect, hiding the evidence | Deliberate deviation: `reset()` does not clear `_dropRing`; documented in the member doc |

## Task Checklist

### Phase 1 — telemetry foundation
- [ ] `CommandTelemetry`: `TransportDropCause`, `TransportDropSample`, ring + `recordTransportDrop`/`drops`/`monitorKillCount`
- [ ] `SSHClientManager`: `_connectedAt`, `_lastDropCause`, monitor drop recording in both `onDead` closures, attribution cleared in `disconnect()`/`_closeClient()`
- [ ] `ConnectionController`: split `_watchForDrop` completions; cause recording with monitor dedup
- [ ] Dashboard: last-drop row + monitor-kill stat
- [ ] Tests: telemetry semantics; manager cause attribution

### Phase 2 — activity-aware monitoring
- [ ] `ConnectionHealthMonitor`: `isBusy` param + `resetFailures()` + busy rules in `_probe()` (tick skip, failure-time re-check)
- [ ] `SSHClientManager`: `registerBusyProbes`, `noteCommandSettled`, `noteStreamActivity`; wire probes at both monitor construction sites
- [ ] `SSHCommandExecutor`: `_run` busy accounting + settle notification; stream count/byte-latch accounting; `transportBusy`/`streamBusy`; constructor registration
- [ ] Unit tests: six monitor scenarios (busy skip, threshold pin, transition, busy-crossed failure, reset, stale-clear)

### Phase 3 — regression & soak
- [ ] Live test: `transportBusy` lifecycle over real sshd, no monitor kill
- [ ] Live test: ≥ 100 MB bulk transfer, zero monitor drops, session still serves commands
- [ ] `flutter analyze` clean
- [ ] `flutter test` full suite green
- [ ] Throttled-link soak: 30+ min fetch/pull/push loop, zero monitor drops

### Phase 4 — docs & upstream
- [ ] `docs/ARCHITECTURE_PLAN.md` §0.1: busy-aware monitoring + drop telemetry description
- [ ] `docs/ARCHITECTURE_PLAN.md` §0.1: remote-host recommendations subsection
- [ ] Upstream issue: bounded `_rekeyPendingPackets` in dartssh2
- [ ] Upstream issue: TCP keepalive option for `SSHSocket.connect`
- [ ] Decide follow-up: RTT-adaptive probe budget (only if soak shows residual starvation)
