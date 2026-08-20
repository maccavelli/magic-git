---
status: "executed"
date: 2026-08-20
associated-madr: "0014-MADR-ssh-engine-next-wave-hardening.md"
owner: [Maintainer]
target-milestone: Next work cycle (post-review)
verified: 2026-08-20
---

# Implement Treat the 2026-08 SSH engine assessment as the next-wave hardening backlog

Associated MADR:
[0014-MADR-ssh-engine-next-wave-hardening.md](./0014-MADR-ssh-engine-next-wave-hardening.md)

This plan is the **single execution vehicle** for that decision's first
tranche **T1–T8, with T3 in scope** (dedicated sync-lane `SSHClient`). It
does not reopen 0011 (busy-pause) or 0013 (dartssh2 3.3.0 pin). A second
engineer following only this file, against the tree as of 2026-08-20,
must produce the same diff.

T3 is not optional in this plan. The MADR allowed slipping it; the
maintainer put it in scope. The degrade-to-dual path and the updated
MaxSessions arithmetic required by MADR Confirmation §2 are specified
in Phase 5, not left as follow-up judgement.

## Goal

Make the SSH engine fail closed on auth lockouts, survive slow-but-moving
network ops, isolate pack transfer onto its own TCP connection, and use
the signals we already collect (channel-open errors, sockets we own, PEM
CPU, sideload stdin, reconnect env) instead of widening timeouts.

**Acceptance criteria**

1. Auto-reconnect **pauses immediately** on an allowlist-miss (auth /
   host-key / key-decode). It still runs the existing 20-attempt, 1/2/4/8/15 s
   schedule for retryable transport errors. Unit-proven in
   `test/auto_reconnect_test.dart`.
2. `git fetch` / `pull` / `push` (and the other `networkTimeout` call
   sites) use an **activity deadline**: silence for `networkTimeout`
   (default 3 min) kills the command; bytes on stdout **or** stderr reset
   that idle timer; an absolute ceiling of
   `max(networkTimeout, 30 min)` plus the existing +30 s watchdog is the
   scheduler deadline. A slow pack that emits progress survives past 3 min;
   a wedged peer that opened a channel and sent nothing still dies on the
   user's configured stall budget.
3. Connect opens **three** handshakes in parallel (command, stream, sync).
   `ExecLane.sync` runs on the sync client when it is attached. If the sync
   handshake fails, the session **degrades to dual** (sync shares the
   command client) and a background redial matches the stream-client
   policy (15 s → 120 s, 5 failures then give up). Command-client death
   still tears everything down. Stream-client death does not close sync,
   and vice versa.
4. MaxSessions comment and dashboard client-count match the arithmetic
   in Phase 5. **Read cap stays 4.** Isolated cap stays 2.
5. A `SSHChannelOpenError` lowers the adaptive read cap (floor 1); a
   clean streak raises it back toward the RTT band. Dashboard shows cap,
   channel-open errors, and single/dual/triple.
6. Every `SSHClient` is built on a socket we own: `TCP_NODELAY` on,
   Darwin `SO_KEEPALIVE` best-effort. Library `keepAliveInterval` stays
   `null`.
7. Encrypted-PEM bcrypt runs off the UI isolate, **once per connect**,
   and the resulting identities are reused by all three clients. Compressed
   reads whose wire size exceeds 256 KiB gunzip off the UI isolate.
8. Sideload uses `stdin.addStream` + `flush()` then `stdin.close()`.
9. Same-host auto-reconnect reuses the last `RemoteEnvironment`; a
   user `disconnect()` or a different profile invalidates the cache.
10. `flutter analyze` and `flutter test` clean. Existing transport tests
    keep their intent. No `live-forge` run. dartssh2 stays exact `3.3.0`.

## Scope

**In scope (T1–T8)**

| ID | Work |
|---|---|
| T1 | Allowlist reconnect classifier; pause on auth/host-key |
| T2 | Activity deadline on `CommandExecutor.execute`; GitService network ops; settings copy |
| T3 | Third `SSHClient` for `ExecLane.sync`; degrade-to-dual; redial; busy split |
| T4 | Channel-open errors feed `AdaptiveReadConcurrency`; dashboard cap / errors / client-count |
| T5 | Native `SSHSocket` wrapper: `tcpNoDelay` + best-effort `SO_KEEPALIVE` |
| T6 | One off-isolate `fromPem` per connect; off-isolate gunzip above 256 KiB |
| T7 | `stdin.addStream` + `session.flush()` for sideloads |
| T8 | Environment-probe cache for same-host reconnect |
| Docs | `ARCHITECTURE_PLAN.md` §0.1 + MADR T14 operational notes that are docs-only |

**Out of scope** (do not implement, even if adjacent)

* T9 RTT-adaptive ping timeout
* T10 compression admission / gzip level change (`-1` stays)
* T11 `waitForExit(timeout:)` (3.1.0 already fails waiters on channel death)
* T12 migrate long-lived streams after stream redial
* T13 `strictKex` / `remoteVersion` on the dashboard (T4 covers cap / errors / count)
* D1 `SSHIdentity` / Secure Enclave
* D2 SFTP sideloads
* D3 dartssh2 fork / `_rekeyPendingPackets` bound / window-size constructor
* D4 transport compression
* D5 re-enable `keepAliveInterval`
* D6 raise `maxConcurrentReads` above 4
* D7 `client.run()` / `runWithResult()`
* D8 fish PATH parse
* `dartssh3` package, caret bump of dartssh2, `live-forge` tests
* New user-facing timeout setting (ceiling is a constant; idle reuses
  the existing Network seconds field)
* DSCP / `IPQoS`

## Prerequisites

* Flutter SDK per `pubspec.yaml`. Commands: `flutter pub get`,
  `flutter analyze`, `flutter test` (`AGENTS.md`).
* New Dart must be analyzer-clean on the first pass (strict-casts,
  `unawaited_futures`, `prefer_final_locals`, `prefer_const_constructors`).
* `lib/core/providers/app_providers.dart` is classified as binary by `rg`.
  Every search or edit check of that file **must** use `rg -a`.
* Do not commit unless the user asks. If they ask for phase commits: after
  that phase's analyze + listed tests, `git add` only that phase's files
  and `git commit --no-edit`. Never `-m` / `-F` / a heredoc message.
* Never run `flutter test --run-skipped -t live-forge`.
* Halt rule: if a Phase 0 fact disagrees with this plan, **stop and update
  this plan**. Do not improvise.

### HEAD facts this plan is written against

Recorded 2026-08-20. Phase 0 re-checks them.

* `pubspec.yaml` — `dartssh2: 3.3.0` (exact). No `dartssh3`.
* Dual client in `SSHClientManager.connect`
  (`lib/core/ssh/ssh_client_manager.dart` ~280–428): command + stream
  handshakes in parallel; stream fail-open; `serializeHostKeyVerifier`;
  stream redial 15 s → 120 s / 5; `_closeClient` closes cmd + stream.
* `_openAuthenticatedClient` uses `SSHSocket.connect` then
  `SSHKeyPair.fromPem` as a constructor argument (~563–606).
* `registerBusyProbes({command, stream})` only. `transportBusy` is
  `_activeCommands > 0` (all lanes) in `SSHCommandExecutor`.
* `_run` always uses `_clientManager.client` (~650). `executeStream` uses
  `streamClient` (~944).
* Reconnect: `ConnectionController._reconnectDelays` 1/2/4/8/15 s,
  `_maxAutoReconnectAttempts = 20`, `_autoReconnect` retries **any**
  `lost` (`app_providers.dart` ~1951–2010). `connect` catch
  (~1437–1468) humanizes and stays `lost` when `reconnecting: true`.
* `GitService.defaultNetworkTimeout = 3 min`, passed as wall-clock
  `timeout:` at seven call sites (fetch, pull, push, pushTags,
  deleteRemoteBranch, deleteRemoteTag, lsRemoteTags). Settings field
  `AppSettings.networkTimeout` seeds it. Caption:
  `settings_sheet.dart:180-184`.
* `CommandExecutor.execute` has no activity parameter. Implementers:
  `SSHCommandExecutor`, `LocalCommandExecutor`, `ProxyCommandExecutor`,
  `ScopedCommandExecutor`, `ActivityCommandExecutor`. Codec:
  `exec_proxy_codec.dart` `ExecuteRequest` / `timeoutMs`.
* `AdaptiveReadConcurrency` is RTT-only. `recordChannelOpenError` is
  increment-only.
* Dashboard `_latencySection` shows `degraded ? 'single' : 'dual'`
  (`dashboard_sheet.dart:352-376`).
* dartssh2 3.3.0: `SSHSocket` is a public abstract class
  (`package:dartssh2/dartssh2.dart` exports `src/socket/ssh_socket.dart`).
  Native connect is `Socket.connect` with **no** `setOption`
  (`ssh_socket_io.dart:12-13`). Channel window 2 MiB / 32 KiB packet.
  `_rekeyPendingPackets` still unbounded; bypass IDs 20–49 and ≤ 4.
  `SSHSession.flush()` exists. `stdin` is a `StreamSink`.
* Dart `SocketOption` public constants: **`tcpNoDelay` only**. Keepalive
  is `setRawOption`. Darwin `SO_KEEPALIVE` = `0x0008`. We are macOS-only.
* Live suite: `test/ssh_live_transport_test.dart` (`integration` tag,
  `_DisposableSshd`). Hardening: `test/ssh_transport_hardening_test.dart`
  (parallel-handshake test currently asserts **2** sockets, lines 99–145).
* Reconnect tests: `test/auto_reconnect_test.dart` (`_FakeManager`).
* Adaptive tests: `test/adaptive_read_concurrency_test.dart`.

## Architecture

```
connect()  ── parallel ──► command SSHClient   (reads, exclusive, isolated)
                      ├──► stream  SSHClient   (executeStream)   fail-open
                      └──► sync    SSHClient   (ExecLane.sync)   fail-open
                                 each: NativeSshSocket (NODELAY + KEEPALIVE)
                                 identities: fromPem once, off UI isolate

ExecLane.sync ──► manager.syncClient  (falls back to command if degraded)
other lanes  ──► manager.client
executeStream ─► manager.streamClient (unchanged fallback)

busy probes (0011, split):
  command monitor ← _activeNonSync > 0
  sync    monitor ← _activeSync > 0
  stream  monitor ← bytes in last 30 s   (unchanged)

command.done error/complete ──► session lost (closes all three)
stream.done  ──► redial stream only
sync.done    ──► fail in-flight sync command; redial sync only

fetch/push timeout:
  pulse idle timer on stdout/stderr bytes
  idle = settings networkTimeout (default 3 min)
  ceiling = max(idle, 30 min)
  scheduler deadline = ceiling + 30 s watchdog
```

### T3 MaxSessions arithmetic (MADR Confirmation §2)

OpenSSH `MaxSessions` is **per TCP connection**, default 10.

| Connection | Channels in the worst overlapping set | of 10 |
|---|---|---|
| Command | 4 reads (+ exclusive is a barrier, so not on top of 4) + up to 2 isolated | 6 |
| Sync | 1 `fetch`/`push` (scheduler: one sync at a time) | 1 |
| Stream | 1 watcher + 1 CI trace | 2 |

Degraded dual (no sync client): command carries 4 reads + 1 sync + ≤2 isolated
= 7; stream 2. Same bound that justified today's cap of 4.

Degraded single (no stream, no sync): 4+1+1+1 ≈ 7 on one connection, as
§0.1 already documents.

**Do not raise `maxConcurrentReads` above 4 in this plan.** T3 buys
isolation, not more fan-out.

### T1 allowlist (MADR Confirmation §4)

`isRetryableReconnectError(Object e)` lives next to
`isTransientTransportError` in `lib/core/ssh/ssh_error_messages.dart`
(ConnectionController already imports it). Allowlist, not denylist:

Retryable:

* `SocketException`
* `SSHSocketError`
* `TimeoutException`
* `SSHHandshakeError`
* `SSHDisconnectError` (peer gone; retrying a new TCP is the point)
* `SSHStateError`
* `SSHAuthAbortError` **only when** unwrapped `reason` is one of the above
* the existing string fallbacks already used by
  `isTransientTransportError` (`connection closed` / `reset` / `broken pipe`)

Not retryable (pause):

* `SSHAuthFailError`
* `SSHAuthAbortError` whose reason is not retryable (kex mismatch,
  `SSHInternalError`, no more auth methods)
* `SSHHostkeyError`
* `SSHKeyDecodeError` / `SSHKeyDecryptError`
* `ArgumentError` (empty profile)
* everything else

`SSHCommandTimeout` / `SSHCommandSuperseded` are not connect errors; they
do not appear here.

## Implementation Steps

### Phase 0 — Inventory (no source change)

Re-read the HEAD facts. Confirm:

1. `SSHSocket` is still exported and implementable.
2. Parallel-handshake test still asserts 2 sockets.
3. `registerBusyProbes` still has two callbacks.
4. dartssh2 still exact 3.3.0; `_rekeyPendingPackets` still unbounded
   (record in the §0.1 note; do not fork).
5. `SSHKeyPair.toPem()` exists and, on a key loaded via `fromPem`, returns
   a PEM we can `fromPem` again without a passphrase. If it does not,
   T6 uses `Isolate.run` returning `List<SSHKeyPair>` directly; if that
   is not Sendable, halt and keep a **single** UI-isolate `fromPem` shared
   by all clients (still a win vs three bcrypts) — do not invent a third
   decode path.

If any fact moved, update this plan before Phase 1.

**Verify:** none (read-only).

---

### Phase 1 — T5 native socket (commit)

**Files**

* **Add** `lib/core/ssh/native_ssh_socket.dart`
* **Edit** `lib/core/ssh/ssh_client_manager.dart` —
  `_openAuthenticatedClient` uses it instead of `SSHSocket.connect`
* **Add** `test/native_ssh_socket_test.dart`

**`NativeSshSocket`**

Implements `SSHSocket`. Factory:

```dart
static Future<SSHSocket> connect(
  String host,
  int port, {
  Duration? timeout,
}) async {
  final socket = await Socket.connect(host, port, timeout: timeout);
  socket.setOption(SocketOption.tcpNoDelay, true);
  try {
    socket.setRawOption(RawSocketOption.fromBool(
      RawSocketOption.levelSocket,
      0x0008, // Darwin SO_KEEPALIVE; we are macOS-only
      true,
    ));
  } catch (_) {
    // Best-effort. tcpNoDelay is the load-bearing option.
  }
  return NativeSshSocket._(socket);
}
```

Delegate `stream`, `sink`, `done`, `close`, `destroy`, `flush` exactly as
`_SSHNativeSocket` does in dartssh2 3.3.0 `ssh_socket_io.dart:16-43`.

`_openAuthenticatedClient` calls `NativeSshSocket.connect(...)` with
`_socketTimeout`. Do **not** pass `keepAliveInterval` on `SSHClient`.
Do **not** add DSCP.

**Tests**

* Bind a `ServerSocket` on loopback, `NativeSshSocket.connect`, assert
  `setOption(tcpNoDelay)` did not throw (round-trip a byte). Keepalive
  failure must not fail the test.
* Existing `test/ssh_transport_hardening_test.dart` parallel-handshake
  test still passes (still 2 sockets until Phase 5).

**Verify:** `flutter analyze` on the touched files;
`flutter test test/native_ssh_socket_test.dart test/ssh_transport_hardening_test.dart`.

---

### Phase 2 — T6 PEM once, off UI isolate; large gunzip (commit)

**Files**

* **Edit** `lib/core/ssh/ssh_client_manager.dart`
* **Edit** `lib/core/ssh/ssh_command_executor.dart` (`openAndDrain`)
* **Add** `test/ssh_key_decode_isolate_test.dart` (or extend hardening)
* **Edit** `test/ssh_command_executor_test.dart` if drain tests need the
  256 KiB branch

**PEM**

Add a top-level or static helper in `ssh_client_manager.dart` (must be
isolate-callable):

```dart
Future<List<SSHKeyPair>> decodeIdentities(String pem, String? passphrase)
```

Implementation (preferred, after Phase 0 confirms `toPem`):

1. `Isolate.run` → `SSHKeyPair.fromPem(pem, passphrase)` then
   `[for (final k in keys) k.toPem()]`.
2. On the client isolate, `SSHKeyPair.fromPem` each unencrypted PEM
   (no passphrase). Bcrypt paid once, off-UI.

`connect` (and stream/sync redial) decode **once** per handshake batch,
pass `List<SSHIdentity>? identities` into `_openAuthenticatedClient`.
Redial of a single client may decode again (rare); do not share a list
across generations.

Socket still closes on `fromPem` throw (the helper throws before
`SSHClient` exists). Generation check still applies after decode: if
superseded, do not attach.

**Gunzip**

In `openAndDrain`, after the wire-byte counter:

* If `compressed` and running total of `stdoutWireBytes` stays
  `≤ 256 KiB`, keep today's `rawStdout.transform(gzip.decoder)` on the
  current isolate.
* If the compressed stream exceeds 256 KiB, collect compressed bytes
  (still charging the **post-gunzip** budget after decode), then
  `Isolate.run(() => gzip.decode(bytes))`, then UTF-8 decode. Charge
  `OutputByteBudget` on the decompressed size. A gzip bomb still hits
  50 MiB and TERM-kills.

Threshold constant: `SSHCommandExecutor.gzipOffloadWireBytes = 256 * 1024`.

Stderr is never gzipped (today); leave it.

**Tests**

* `decodeIdentities` on a generated unencrypted ed25519 PEM (no bcrypt)
  round-trips and can construct `SSHClient` identities. Encrypted-PEM
  bcrypt coverage is optional if we lack a fixture; do not add live keys.
* Compressed drain of a payload `> 256 KiB` still splits the exit
  trailer and respects the byte budget (extend existing executor tests
  with a fake session if one exists; otherwise a live-sshd compressed
  `dd` in Phase 10).

**Verify:** `flutter analyze`;
`flutter test test/ssh_command_executor_test.dart test/ssh_transport_hardening_test.dart`.

---

### Phase 3 — T1 reconnect classifier (commit)

**Files**

* **Edit** `lib/core/ssh/ssh_error_messages.dart` — add
  `isRetryableReconnectError`
* **Edit** `lib/core/providers/app_providers.dart` (`rg -a`) —
  `_autoReconnect` / `connect` catch when `reconnecting: true`
* **Edit** `test/auto_reconnect_test.dart`
* **Edit** `test/ssh_error_messages_test.dart`

**Behaviour**

After `reconnect()` / inside `connect`'s catch when `reconnecting` is
true: if `!isRetryableReconnectError(e)`, set

```dart
state = state.copyWith(reconnecting: false);
```

and **return** from `_autoReconnect` without incrementing toward 20.
Stay `ConnectionPhase.lost` so the user can edit credentials. Do not
`disconnect()` beyond what the failed `connect` already did.

Retryable errors keep today's loop.

Host-key *decline* already resets to disconnected (`_hostKeyCancelledAttempt`);
leave that branch.

**Tests**

* `_FakeManager.failNext` with `SSHAuthFailError` (or a thrown
  `SSHAuthFailError` from a new override) → `reconnectAttempt` stops at 1,
  `reconnecting == false`, `phase == lost`.
* `SocketException` / generic `Exception('network lost')` still walks the
  20-attempt schedule (existing tests remain valid; adjust if they assumed
  generic `Exception` is retryable — today's fake throws `Exception`, which
  is **not** on the allowlist).

  **Load-bearing:** the current fake throws `Exception('reconnect failed')`.
  After T1 that would **pause**. Change the fake's network failure to
  `SocketException` (or `SSHSocketError`) so existing "keeps retrying"
  tests still describe network loss. Add a separate auth-fail test.

**Verify:** `flutter analyze`;
`flutter test test/auto_reconnect_test.dart test/ssh_error_messages_test.dart`.

---

### Phase 4 — T2 activity deadline (commit)

**Files**

* **Add** `lib/core/exec/activity_deadline.dart` — `ActivityDeadline`
* **Edit** `lib/core/ssh/ssh_command_executor.dart` — `execute` signature,
  `_run` / `openAndDrain`, scheduler deadline
* **Edit** `lib/core/exec/local_command_executor.dart` — same param, pulse
  on stdout/stderr chunks
* **Edit** `lib/core/exec/proxy_command_executor.dart`,
  `scoped_command_executor.dart`, `activity_command_executor.dart` —
  pass-through
* **Edit** `lib/core/exec/exec_proxy_codec.dart` — optional `activityIdleMs`;
  omit or 0 = wall clock (old pop-outs keep working)
* **Edit** `lib/core/git/git_service.dart` — `_run` + seven network call
  sites
* **Edit** `lib/features/settings/settings_sheet.dart` — section copy
* **Add** `test/activity_deadline_test.dart`
* **Edit** tests that construct `ExecuteRequest` if any assert field count

**`ActivityDeadline`**

```dart
class ActivityDeadline {
  ActivityDeadline({required this.idle, required this.ceiling});
  final Duration idle;
  final Duration ceiling;
  // pulse() records DateTime.now()
  // Future<T> wait(Future<T> inner) — completes with TimeoutException
  //   if idle elapses without pulse OR ceiling elapses from start
}
```

When `activityIdle == null`, `execute` uses today's `.timeout(timeout)`
unchanged.

When `activityIdle != null`:

* `timeout` is the **ceiling**.
* Pulse on every stdout and stderr **raw** chunk (before gunzip).
* Throw `SSHCommandTimeout` on idle or ceiling, same cleanup as today
  (`timedOut` flag, TERM→KILL).
* Scheduler `deadline: timeout + watchdogMargin` (ceiling, not idle).

**GitService**

```dart
static const Duration defaultNetworkCeiling = Duration(minutes: 30);
```

`_run` gains `Duration? activityIdle`. Network call sites:

```dart
timeout: networkTimeout > defaultNetworkCeiling
    ? networkTimeout
    : defaultNetworkCeiling,
activityIdle: networkTimeout,
lane: …,
```

Seven sites: `fetch`, `pull`, `push`, `pushTags`, `deleteRemoteBranch`,
`deleteRemoteTag`, `lsRemoteTags`. `pull` is exclusive but still a pack
transfer — include it.

Do **not** apply this to `commitTimeout` / `defaultHookTimeout`.

**Settings copy** (`settings_sheet.dart:180-184`):

Replace "How long a command may run before it is considered hung" with:
network seconds is the **stall** budget (no output for that long); a
slow fetch that is still printing may run up to 30 minutes. Commit
timeout is still a wall clock.

**Tests**

* `ActivityDeadline`: pulse every 10 ms with idle 50 ms, ceiling 1 s →
  completes; no pulse, idle 50 ms → `TimeoutException`; pulse forever,
  ceiling 50 ms → `TimeoutException`.
* GitService default: fetch path passes ceiling 30 min / idle 3 min
  (unit-test via a recording executor if one exists; otherwise assert
  the constants and the `_run` arguments through a fake `CommandExecutor`).

**Verify:** `flutter analyze`;
`flutter test test/activity_deadline_test.dart test/ssh_command_executor_test.dart test/local_command_executor_test.dart test/exec_proxy_codec_test.dart test/git_service_test.dart`.

---

### Phase 5 — T3 dedicated sync client (commit)

This is the architectural phase. Do not raise the read cap.

**Files**

* **Edit** `lib/core/ssh/ssh_client_manager.dart` — third client, redial,
  busy probe, close paths
* **Edit** `lib/core/ssh/ssh_command_executor.dart` — client selection,
  busy split
* **Edit** `lib/core/exec/command_lanes.dart` — MaxSessions comment
* **Edit** `test/ssh_transport_hardening_test.dart` — 3 sockets
* **Edit** `test/ssh_command_executor_test.dart` / hardening — lane routing
* **Edit** `docs/ARCHITECTURE_PLAN.md` §0.1 (may wait for Phase 9 if the
  diff is only prose; prefer updating the dual-client paragraph here so
  tests and docs do not disagree mid-branch)

**Manager API**

```dart
SSHClient? _syncClient;
ConnectionHealthMonitor? _syncHealth;
Timer? _syncRedialTimer;
int _syncRedialFailures = 0;
bool Function()? _syncBusyProbe;

SSHClient? get syncClient => _syncClient ?? _client;
bool get syncClientDegraded => _client != null && _syncClient == null;
bool get streamClientDegraded => … // unchanged
int get attachedClientCount =>
    (_client == null ? 0 : 1) +
    (_streamClient != null ? 1 : 0) +
    (_syncClient != null ? 1 : 0);
```

`registerBusyProbes({command, stream, sync})`.

`_syncAuthTimeout = _streamAuthTimeout` (10 s). Reuse
`streamRedialDelay` / `_maxRedialFailures` for sync redial. **Separate**
failure counter and timer from stream.

**`connect`**

Three parallel `_openAuthenticatedClient` futures, same serialized
verifier, **one** `decodeIdentities` result passed to all three.

* Command failure: close stream **and** sync futures' clients; rethrow
  (unchanged fail-closed for the session).
* Stream failure: log, `null`, existing redial.
* Sync failure: log, `null`, `_onSyncClientLost(gen)` (new, copy of
  `_onStreamClientLost` against `_syncClient`).

Supersession: close all three new clients, leave previous attached.

Winning attempt: retire previous cmd / stream / **sync** (identity-guarded
double-close). Attach monitors:

* Command `onDead`: record drop; close stream if distinct; close sync if
  distinct; `unawaited(cmd.close())`. Do **not** null `_client` (drop
  path still observes `done`).
* Stream `onDead`: close **only** that stream client; redial stream.
* Sync `onDead`: close **only** that sync client; redial sync.

`_closeClient`: stop three monitors, cancel two redial timers, close
three clients, clear `_redialProfile`.

**Executor**

```dart
final client = lane == ExecLane.sync
    ? _clientManager.syncClient
    : _clientManager.client;
```

Generation pin still uses `generation` + `clientGeneration` (the
attached **command** generation). Sync client is of the same generation
or we are degraded to command; a mid-handshake reconnect still
supersedes.

Busy split:

* `_activeSync` / `_activeNonSync` instead of a single `_activeCommands`
  (or keep a total for telemetry `transportBusy` = either > 0).
* `registerBusyProbes(command: () => _activeNonSync > 0, stream: …,
  sync: () => _activeSync > 0)`.
* Increment the matching counter around `_runBody`. Settle still resets
  the monitor for that client (`noteCommandSettled` /
  `noteSyncSettled`).

`uploadBytes` stays isolated on the **command** client (not sync).

**`command_lanes.dart` comment** (replace the "4 reads + 1 sync + 1
watcher + 1 CI ≈ 7" paragraph) with the Phase 5 table. Keep
`maxConcurrentReads = 4` and `maxReadCapHardLimit = 8`.

**Tests**

* Parallel-handshake test: expect **3** accepted sockets in 5 s;
  `disconnect()` still aborts promptly; `client` / `streamClient` /
  `syncClient` getters null after disconnect.
* Fake-sshd or unit: sync handshake throw → `syncClientDegraded == true`,
  `syncClient` identical to `client`, connect still succeeds.
* Executor: `ExecLane.sync` calls `execute` on the object returned by
  `syncClient` (injectable manager with distinct fake clients if we can
  do it without a real sshd; otherwise live test in Phase 10:
  `MaxSessions 2` so the third handshake degrades).
* Stream death does not close command (existing); add: sync death does
  not close command.

**Verify:** `flutter analyze`;
`flutter test test/ssh_transport_hardening_test.dart test/ssh_command_executor_test.dart test/connection_health_monitor_test.dart`.

---

### Phase 6 — T4 adaptive cap from channel-open errors + dashboard (commit)

**Files**

* **Edit** `lib/core/ssh/adaptive_read_concurrency.dart`
* **Edit** `lib/core/ssh/ssh_command_executor.dart` — call `onChannelOpenError`
  / `onSuccess` next to `recordChannelOpenError`
* **Edit** `lib/features/dashboard/dashboard_sheet.dart`
* **Edit** `test/adaptive_read_concurrency_test.dart`
* **Edit** `test/dashboard_sheet_test.dart` if it pins 'dual'

**Adaptive**

Add `_errorFloor` (starts at `ceiling`).

* `onChannelOpenError()`: `_errorFloor = max(1, effectiveCap - 1)`; set
  `_effective = min(_effective, _errorFloor)`; notify if changed; clear
  RTT pending.
* `onSuccess()`: after `consecutiveRequired` successes, `_errorFloor =
  min(ceiling, _errorFloor + 1)`; then `_effective = min(rttBand or
  current, _errorFloor)`.
* `onRtt`: compute band as today, then `_effective = min(band, _errorFloor)`.
* `reset()`: `_errorFloor = ceiling`, effective → `noSampleCap`.

Never exceeds `ceiling` (still 4). Floor 1.

Wire: `runWithRetries` already records channel-open errors. Also call
`_adaptiveReads.onChannelOpenError()`. On a successful `_runBody`,
`_adaptiveReads.onSuccess()`.

**Dashboard** (`_latencySection`)

Replace the dual/single stat with:

* client count label: `single` / `dual` / `triple` from
  `attachedClientCount` (orange if `< 3` while connected)
* new stats: `adaptiveReadCap`, `channelOpenErrors`

Keep the sparkline. Do not add `strictKex` (T13).

**Tests**

* Channel-open error drops 4→3 immediately; three successes raise
  `_errorFloor`; RTT band 2 still wins over a high error floor.
* `reset` restores no-sample cap 3.

**Verify:** `flutter analyze`;
`flutter test test/adaptive_read_concurrency_test.dart test/dashboard_sheet_test.dart`.

---

### Phase 7 — T7 sideload `addStream` + `flush` (commit)

**Files**

* **Edit** `lib/core/ssh/ssh_command_executor.dart` `openAndDrain`
* **Edit** `test/ssh_command_executor_test.dart` if stdin is asserted

Replace:

```dart
if (stdin != null) {
  s.write(stdin);
}
await s.stdin.close();
```

with:

```dart
if (stdin != null) {
  await s.stdin.addStream(Stream<List<int>>.value(stdin));
  await s.flush();
}
await s.stdin.close();
```

Empty stdin: still `close()` only (local executor contract). Timeout
during `addStream` is covered by the existing openAndDrain timeout /
activity deadline.

Do **not** switch to SFTP.

**Verify:** `flutter analyze`;
`flutter test test/ssh_command_executor_test.dart test/ssh_transport_hardening_test.dart`.

---

### Phase 8 — T8 environment probe cache (commit)

**Files**

* **Edit** `lib/core/providers/app_providers.dart` (`rg -a`)
  `_resolveEnvironment`, `disconnect`, `connect`
* **Edit** `test/connection_env_reset_test.dart` and/or
  `test/environment_probe_test.dart`

**Cache**

On `ConnectionController`:

```dart
String? _envCacheKey;
RemoteEnvironment? _envCache;
```

Key: `'${profile.host}|${profile.port}|${profile.username}'`.

* After a successful `_resolveEnvironment`, store env + key.
* At the start of `_resolveEnvironment`, if `reconnecting == true` and
  the key matches and `_envCache != null`, `configureEnvironment` from
  the cache and return (still set forge-token neutralization; still
  publish `binaryEnvironmentProvider`).
* `disconnect()` (user or teardown) clears the cache.
* Connect to a different key ignores the old cache (overwrite after the
  new probe).
* Local backend: do **not** use this cache (`ConnectionBackend.local`
  always probes — Finder PATH is cheap and can change).

Do not cache across process restarts. Do not skip `reprobeBinaries`.

**Tests**

* Fake executor whose `execute` counts the probe script: first connect
  probes once; simulated drop + reconnect with the same profile does not
  increment; `disconnect()` then connect increments again.
* Different username does not hit the cache.

**Verify:** `flutter analyze`;
`flutter test test/connection_env_reset_test.dart test/environment_probe_test.dart test/auto_reconnect_test.dart`.

---

### Phase 9 — Docs (commit)

**Files**

* **Edit** `docs/ARCHITECTURE_PLAN.md` §0.1
* **Edit** `docs/0014-MADR-ssh-engine-next-wave-hardening.md` — "Implementation
  plan" line already points here; add T14 operational bullets to §0.1,
  do **not** change MADR status (still `proposed` until the maintainer
  accepts)

**§0.1 replacements**

* Dual client → triple client, fail-open independently for stream and
  sync, redial both, command `done` owns session loss.
* Busy-pause split: command vs sync vs stream.
* Activity deadline for network ops; settings = stall budget; 30 min
  ceiling.
* Reconnect allowlist; 20 attempts are transport-only.
* Native socket NODELAY + keepalive; library keepalive still off.
* Adaptive cap also tracks channel-open errors; dashboard single/dual/triple.
* PEM decode once off-UI; gzip offload > 256 KiB.
* Env probe cached on same-host auto-reconnect.
* MaxSessions table from Phase 5.
* Known gaps: drop "adaptive reacts only to RTT", drop "env probe on
  reconnect critical path", drop "cap not on dashboard". Keep: streams
  opened while degraded stay until restart (T12); fish PATH (D8);
  unbounded rekey buffer (D3); T9–T11.

**T14 operational notes** (docs, not code)

* `ClientAliveInterval` ≤ 60 s, `ClientAliveCountMax` ≥ 3; OpenSSH 10.5
  fixed ClientAlive math — do not require 10.5.
* Do not set a short `ChannelTimeout` on `session` if `fswatch` should live.
* `PerSourcePenalties`: T1 is the client-side fix; do not hammer a host
  with failed auth.
* Leave `RekeyLimit` without a time component unless you understand idle
  rekey vs our ping.
* `MaxSessions` 10 is enough for triple-client at read cap 4; do not
  lower it to 1.

**Verify:** markdown only; no analyzer.

---

### Phase 10 — Full gate (no extra commit if clean)

```sh
flutter analyze
flutter test
flutter test test/ssh_live_transport_test.dart
```

Live suite (`integration` tag) self-skips without `/usr/sbin/sshd`. When
present, add (if not already covered):

* Connect reports `attachedClientCount == 3` against default sshd.
* A 100 MB `dd` / existing bulk test: zero monitor kills, reads still
  work **during** a long `cat` on the sync client (or `sleep` + stream of
  bytes on `ExecLane.sync` while a short `echo` on `ExecLane.read`
  returns).
* Auth-fail reconnect does not loop (if the live harness can present a
  bad password without hanging — otherwise unit tests own this).

Never `live-forge`.

If analyze or unit tests fail, fix in the phase that introduced the
break, do not pile a "cleanup" phase.

## Verification

Per-phase commands are listed above. The plan is done when:

| # | Check |
|---|---|
| 1 | `flutter analyze` exit 0 |
| 2 | `flutter test` exit 0 |
| 3 | Parallel-handshake test expects 3 sockets |
| 4 | `isRetryableReconnectError` unit table covers allow and deny |
| 5 | `ActivityDeadline` idle vs ceiling tests pass |
| 6 | Adaptive error-floor tests pass |
| 7 | No `keepAliveInterval:` other than `null` |
| 8 | No `dartssh3` in `pubspec.yaml` |
| 9 | `maxConcurrentReads` default still 4 |
| 10 | §0.1 describes triple-client + degrade-to-dual |

## Rollout and Rollback

**Rollout.** Unsigned Mac build via `./build_macos.sh --unsigned --install`
only when the user asks. No migration, no settings schema change (the
Network seconds field is reused as stall budget; ceiling is a constant).
Pop-out windows: missing `activityIdleMs` ⇒ wall clock (safe).

**Rollback.** Revert the phase commits in reverse order. T3 is the only
phase that changes connect topology; reverting Phase 5 while keeping
T1/T2/T5/T6 is a valid partial rollback (sync getter gone, executor
uses command client again). T5 socket wrapper can remain under a dual
or triple manager.

**Risks**

* Three unauthenticated TCP connections at once vs `MaxStartups`
  (default 10:30:100). Acceptable. If a host refuses the third, we
  degrade; we do not fail connect.
* `git fetch` quiet period longer than `networkTimeout` with no stderr
  progress. Default idle is 3 min, which is today's kill budget, so this
  is not a regression. Users who set Network seconds to 5 to "fail fast"
  may now kill a silent counting-objects phase — document in settings
  copy, do not special-case git.
* Shared `List<SSHKeyPair>` across three authenticating clients. If
  dartssh2 mutates the list, pass `List<SSHKeyPair>.of(decoded)` per
  client (shallow copy). Halt only if auth flakes in the live suite.
* `SO_KEEPALIVE` `setRawOption` throws inside the sandbox. Caught;
  `tcpNoDelay` still applies.

## Halt conditions (do not improvise)

1. `SSHSocket` is no longer a public abstract class → drop T5 from this
   plan (update the MADR) and continue T1–T4, T6–T8.
2. `SSHKeyPair` cannot leave an isolate and `toPem` is encrypted → one
   UI-isolate `fromPem` shared by three clients; still not three bcrypts.
3. Parallel connect against loopback sshd cannot open 3 sockets in 5 s
   for a reason other than our scheduling (e.g. test sshd
   `MaxStartups 1`) → fix the test sshd config, do not serialize
   handshakes.
4. Any phase wants to set `keepAliveInterval` non-null, raise the read
   cap, adopt SFTP, or add `dartssh3` → stop; that is a different MADR.
