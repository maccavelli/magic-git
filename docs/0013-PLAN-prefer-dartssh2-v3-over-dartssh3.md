---
status: "draft"
date: 2026-08-19
associated-madr: "0013-MADR-prefer-dartssh2-v3-over-dartssh3.md"
owner: [Maintainer]
target-milestone: Next work cycle (post-review)
reassessed: "2026-08-19 against dartssh2 3.3.0 (pub.dev changelog, GitHub v3.3.0 / 8585dc4, API docs)"
---

# Implement Prefer dartssh2 3.3.0 over the dartssh3 package

Associated MADR:
[0013-MADR-prefer-dartssh2-v3-over-dartssh3.md](./0013-MADR-prefer-dartssh2-v3-over-dartssh3.md)

This plan is the **single execution vehicle** for that decision. It absorbs
the mechanical bump from
[0012-PLAN-adopt-dartssh2-v3.md](./0012-PLAN-adopt-dartssh2-v3.md) and adds
the 0013-only work (dartssh3 rejection gates, `SSHPacketError` copy,
`handshakeTimeout`, drop-reason surfacing that does **not** wait on MADR
0011). Do not execute 0012-PLAN in parallel.

## Goal

Keep the import as `package:dartssh2/dartssh2.dart`. Pin **exact**
`dartssh2` **3.3.0**. Never add the `dartssh3` package. Migrate the 3.0.0
`SSHClient.close(): Future<void>` break, adopt the in-scope 3.x diagnostics
and official-docs timeouts, and make a peer `SSH_MSG_DISCONNECT` reason
visible and testable.

A second engineer following only this file, against the tree as of
2026-08-19, must produce the same diff.

## Official sources (reassessment 2026-08-19)

Grounded in, not paraphrased from secondary notes:

* Changelog / README: https://pub.dev/packages/dartssh2/changelog ,
  https://pub.dev/packages/dartssh2 (3.3.0, published 2026-08-18).
* GitHub release `v3.3.0` (`8585dc4`),
  https://github.com/vicajilau/dartssh2/releases/tag/v3.3.0 .
* API: `SSHClient.close` → `Future<void>`;
  `SSHDisconnectError(int reasonCode, String message)` (RFC 4253 §11.1);
  `handshakeTimeout` = max wait for **transport handshake**;
  `SSHKexType.dh1Sha1` still implemented;
  `SSHKexType.x25519Rfc` docs: OpenSSH matches kex names literally and
  without the RFC spelling the handshake dies with
  `"no matching key exchange method found"`.
* 3.3.0 source `lib/src/ssh_client.dart` (tag `v3.3.0`):
  `done` is `_transport.done` (peer disconnect after auth is
  `SSHDisconnectError` on `done`);
  pre-auth transport errors complete `authenticated` as
  **`SSHAuthAbortError('Connection closed before authentication', error)`**
  with `reason` the inner `SSHError`;
  handshake timer fires `SSHHandshakeError('Handshake timed out')`;
  `close()` cancels both timeout timers, terminates waiters with
  `SSHStateError('SSH client closed')`, then `await _transport.close()`.
* README best practices that this plan must follow:
  `await client.close()`; always pass `onVerifyHostKey` (omit = accept
  every host key); never `disableHostkeyVerification: true` outside
  tests; set `handshakeTimeout` (official example is 15 s, same as our
  `_socketTimeout`); leave algorithm defaults alone; `execute()` when
  you need streams/stdin/kill; library `keepAliveInterval` defaults to
  10 s — we keep `null` because `ConnectionHealthMonitor` reply-checks.
* RFC 4253 §11.1 / IANA: reason **3** =
  `SSH_DISCONNECT_KEY_EXCHANGE_FAILED`. Reason **11** =
  `SSH_DISCONNECT_BY_APPLICATION`. Unit tests use **3**, matching the
  changelog's kex-mismatch description. Do not invent code 11.

Deviations from the README (recorded, not accidental):

* Exact pin `3.3.0` instead of `^3.3.0` — churn bound (six 3.x releases
  in ~48 h). Official install snippet is a caret.
* Library `authTimeout` is **not** set. Official docs recommend it, but
  it cannot pause for a host-key prompt; our pausable wrapper around
  `authenticated` can. Handshake timeout (library) + pausable auth
  (ours) is the composition.
* `unawaited(close())` is used only where the enclosing callback is
  synchronous (`onDead`) or where awaiting would delay attaching a
  winning client. Every already-`async` teardown **awaits**, which is
  what the 3.0.0 `Future<void> close()` break exists for.

## Scope

**In scope**

1. Dependency pin `dartssh2: 3.3.0` (exact, no caret) and lockfile update.
2. Mechanical `unawaited(SSHClient.close())` at every current call site.
3. `handshakeTimeout: _socketTimeout` on the `SSHClient` constructor.
4. `humanizeSshError` branches for `SSHDisconnectError` (and the
   `SSHAuthAbortError` wrapper 3.3.0 uses pre-auth), `SSHHandshakeError`,
   and `SSHPacketError`; a pure `peerDisconnectReason` /
   `transportLostMessage` helper that **unwraps** `SSHAuthAbortError.reason`.
   `SSHDisconnectError`, `SSHHandshakeError`, and `SSHPacketError` are
   **not** transient retries.
5. Split `_watchForDrop` so the thrown error reaches `_onTransportClosed`,
   and surface `transportLostMessage(error)` on `ConnectionState.error` plus
   the reconnecting overlay and the lost landing card.
6. One-line connect log of `remoteVersion` + `strictKex`.
7. Re-verify `_rekeyPendingPackets` against the 3.3.0 source; file the
   upstream issue if still unbounded.
8. Tests listed in [Verification](#verification). Docs touch listed in
   Phase 7.

**Out of scope** (do not implement, even if they look adjacent)

* Adding `dartssh3:` to `pubspec.yaml` or renaming the import.
* MADR 0011 busy-pause / `TransportDropSample` / `TransportDropCause`.
  This plan does not create those types. If 0011 lands later, it must call
  `peerDisconnectReason` rather than re-parse the error.
* Replacing the pausable auth wrapper with library `authTimeout`.
* Re-enabling `keepAliveInterval`.
* Passing `disableHostkeyVerification: true`.
* Passing `SSHAlgorithms` to pin CTR/CBC or revive `dh-group1-sha1` /
  `hmac-md5` / truncated hmac in production code.
* Switching `execute()` to `run()` / `runWithResult()`.
* Adopting SFTP for uploads.
* `session.stdin.addStream` for sideloads.
* `compute(...)` around `SSHKeyPair.fromPem`.
* `SSHIdentity` / Secure Enclave / `shouldProbe`.
* TCP keepalive / `SocketOption.tcpKeepAlive`.
* Transport-level compression (the library still has none).
* `live-forge`-tagged tests.

## Relationship to 0011 and 0012

| Record | Status at plan-write (2026-08-19) | This plan's stance |
|---|---|---|
| 0011 MADR + PLAN | proposed / draft; **not implemented**. `command_telemetry.dart` has no `TransportDropSample`. `_watchForDrop` (`app_providers.dart:1913-1934`) discards the error and hardcodes `'Connection lost'`. | Do **not** wait. Land reason copy on `ConnectionState.error` and the two UI surfaces that already exist. 0011, when executed, consumes `peerDisconnectReason`. |
| 0012 MADR + PLAN | proposed / draft. Same 3.3.0 bump; assumed 0011 telemetry already existed. | Absorbed. Close-site table and pin rule come from 0012. Extra 0013 work is listed above. Execute **this** file only. |

`lib/core/providers/app_providers.dart` is classified as binary by `rg`.
Every search or edit check of that file **must** use `rg -a`.

## Prerequisites

* Flutter SDK per `pubspec.yaml` (`sdk: ^3.12.2`). Commands:
  `flutter pub get`, `flutter analyze`, `flutter test` (`AGENTS.md`).
* New Dart must be analyzer-clean on the first pass (strict-casts,
  `unawaited_futures`, `prefer_final_locals`, `prefer_const_constructors`).
* Do not commit unless the user asks. If they ask for phase commits: after
  that phase's analyze + tests, `git add` only that phase's files and
  `git commit --no-edit`. Never `-m` / `-F` / a heredoc message.
* Never run `flutter test --run-skipped -t live-forge`.
* Halt rule: if a Phase 0 or Phase 1a fact disagrees with this plan (close
  site count, `close()` return type, `SSHDisconnectError` constructor
  shape), **stop and update this plan**. Do not improvise.

### HEAD facts this plan is written against

Recorded 2026-08-19. Phase 0 re-checks them.

* `pubspec.yaml:39` — `dartssh2: ^2.22.5`
* `pubspec.lock` — `dartssh2` `version: "2.22.5"`
* No `dartssh3` anywhere in `pubspec.yaml` / `pubspec.lock`
* `package:dartssh2/dartssh2.dart` imports (exactly four):
  `lib/core/ssh/ssh_client_manager.dart`,
  `lib/core/ssh/ssh_command_executor.dart`,
  `lib/core/ssh/ssh_error_messages.dart`,
  `test/ssh_command_executor_test.dart`
* 16 `SSHClient.close()` sites, all in `ssh_client_manager.dart` (table in
  Phase 1b). `ssh_command_executor.dart` only closes `SSHSession` / stdin.
* `SSHClient(` constructed once, `ssh_client_manager.dart:541-565`. Does
  **not** pass `handshakeTimeout` or library `authTimeout`. Passes
  `keepAliveInterval: null`.
* Auth timeout is **our** pausable wrapper around `client.authenticated`
  (`:581-585`), not the library named arg. The 0013 MADR forbids replacing
  it.
* `SSHPacketError` already exists in dartssh2 **2.22.5**
  (`ssh_errors.dart:59-64`, message-only) and is already in
  `isTransientTransportError` (`ssh_command_executor.dart:535`). 3.3.0
  changes *when* it is raised (malformed packets that used to be
  `RangeError`), not whether the type exists.
* `SSHDisconnectError` does **not** exist in 2.22.5 `ssh_errors.dart`. It
  arrives with 3.3.0. Confirmed against tag `v3.3.0` source:
  `SSHDisconnectError(this.reasonCode, this.message)` (`int`, `String`).
  Re-confirm after `flutter pub get` (halt if the shape moved).
* `unawaited` is already available (`import 'dart:async';` at
  `ssh_client_manager.dart:1`).
* Drop path: `app_providers.dart:1913-1934` (use `rg -a`).
* Reconnecting UI: `lib/features/app_shell.dart:86-189` (`_ReconnectingOverlay`
  has `host` + `attempt`, no reason).
* Lost landing: `lib/features/connection/connection_landing.dart:61-80`
  hardcodes `'Connection lost'` and does not read `connection.error`.
* Dashboard connection card (`dashboard_sheet.dart:174-179`) shows
  reconnect attempt only.
* Live suite: `test/ssh_live_transport_test.dart` (`integration` tag,
  `_DisposableSshd`, self-skips if `/usr/sbin/sshd` is missing).
* Humanize tests: `test/ssh_error_messages_test.dart` (three tests, no
  disconnect/packet cases).

## Architecture

No new types in the executor seam. No new packages. Dual-client,
generation pinning, busy-pause (0011), and exec-channel upload are
untouched.

```
sshd SSH_MSG_DISCONNECT
        │
        ▼
dartssh2 3.3.0  →  SSHClient.done completes with SSHDisconnectError
        │
        ▼
ConnectionController._watchForDrop  (catchError keeps the Object)
        │
        ├── peerDisconnectReason(error)        // pure, unit-tested
        └── transportLostMessage(error)        // "Connection lost" or
                                               // "Connection lost (11: …)"
        │
        ▼
ConnectionState.error
        ├── _ReconnectingOverlay.reason
        └── ConnectionLanding lost subtitle
```

`CommandTelemetry` is not extended here. When 0011 adds
`TransportDropSample.peerReason`, the field is `peerDisconnectReason(error)`.

### Deterministic `close()` rule

3.0.0 made `close()` `Future<void>` specifically so callers can wait for
socket and channel teardown (README examples are all `await client.close()`;
the method cancels handshake/auth timers, fails pending waiters with
`SSHStateError('SSH client closed')`, then `await _transport.close()`).

Rule:

* Enclosing function is already `async` **and** is discarding the client
  (will not attach it): **`await`**.
* Enclosing function is **synchronous** (`onDead`) or must attach a new
  client before old teardown finishes: **`unawaited`**.

`dart:async` `unawaited` accepts `Future<void>?`. Do **not** bulk-replace.
Apply the Phase 1b table by hand.

### Deterministic copy

Add to `lib/core/ssh/ssh_error_messages.dart` (same library as
`humanizeSshError`):

```dart
/// Peer `SSH_MSG_DISCONNECT` reason, or null when [error] is not one.
///
/// 3.3.0 surfaces the peer message as [SSHDisconnectError] on
/// [SSHClient.done]. The same event *before* auth completes
/// [SSHClient.authenticated] as [SSHAuthAbortError] whose [SSHAuthAbortError.reason]
/// is that [SSHDisconnectError] (`ssh_client.dart` `_handleTransportClosed`).
String? peerDisconnectReason(Object? error) {
  if (error is SSHDisconnectError) {
    return '${error.reasonCode}: ${error.message}';
  }
  if (error is SSHAuthAbortError) {
    return peerDisconnectReason(error.reason);
  }
  return null;
}

/// Lost-session banner. Stable when [error] is null or not a peer disconnect.
String transportLostMessage(Object? error) {
  final peer = peerDisconnectReason(error);
  if (peer == null) return 'Connection lost';
  return 'Connection lost ($peer)';
}
```

`humanizeSshError` gains typed branches **above** the existing
`SSHAuthFailError || SSHAuthAbortError` catch-all (otherwise a pre-auth
peer disconnect is mislabeled "Authentication failed"):

```dart
if (error is SSHDisconnectError) {
  return 'The host closed the connection '
      '(${error.reasonCode}: ${error.message}).';
}
final abortedPeer = error is SSHAuthAbortError
    ? peerDisconnectReason(error.reason)
    : null;
if (abortedPeer != null) {
  return 'The host closed the connection ($abortedPeer).';
}
if (error is SSHHandshakeError) {
  return 'Timed out during the SSH handshake.';
}
if (error is SSHPacketError) {
  return 'The SSH session received a malformed packet.';
}
```

Exact strings are the test oracles in Phase 6. Do not paraphrase them later.

`SSHCommandExecutor.isTransientTransportError`: add
`e is SSHDisconnectError` and `e is SSHHandshakeError` to the **never-retry**
list (the block that already contains `SSHCommandTimeout` / `SSHAuthError`).
**Move** `e is SSHPacketError` out of the retry list into that same
never-retry list. 3.3.0 raised malformed packets to typed `SSHError`
precisely so they are protocol failures, not transport blips — retrying
the same peer is wrong.

## Implementation Steps

Execute phases in order. Do not start Phase *N+1* until Phase *N*'s gate
passes. Line numbers below are HEAD (2026-08-19). Re-resolve with
`rg -n` at the start of each phase if the file has moved.

### Phase 0 — Preflight (read-only)

No edits.

1. Confirm the HEAD facts in [Prerequisites](#prerequisites). Commands:

   ```sh
   rg -n "dartssh2:|dartssh3:" pubspec.yaml pubspec.lock
   rg -n "package:dartssh2/dartssh2.dart|package:dartssh3/" --glob '*.dart'
   rg -n "\\.close\\(" lib/core/ssh/ssh_client_manager.dart
   rg -n "SSHClient\\(" lib/core/ssh/ssh_client_manager.dart
   rg -n "waitForExit|authTimeout|keepAliveInterval|handshakeTimeout|disableHostkey" lib/core/ssh/
   rg -a -n "_watchForDrop|_onTransportClosed" lib/core/providers/app_providers.dart
   ```

2. Expected: one `dartssh2: ^2.22.5`, no `dartssh3`, four dartssh2 imports,
   16 `close()` hits in the manager, one `SSHClient(`, `waitForExit` present,
   no `handshakeTimeout`, `keepAliveInterval: null`, `_watchForDrop` at
   ~1913.

3. **Gate.** If any expected line is missing or counted differently, stop
   and edit this plan's tables. Do not migrate from a stale table.

### Phase 1 — Pin 3.3.0 and migrate `close()`

**1a. Pin.** In `pubspec.yaml:39` replace

```yaml
  dartssh2: ^2.22.5
```

with

```yaml
  dartssh2: 3.3.0
```

No caret. Run `flutter pub get`. Confirm `pubspec.lock` shows
`version: "3.3.0"` for `dartssh2` and that `dartssh3` is absent.

Open the resolved sources (path will be under the machine's pub cache,
typically `~/.pub-cache/hosted/pub.dev/dartssh2-3.3.0/`) and record:

* `SSHClient.close` signature is `Future<void> close()`.
* `SSHDisconnectError` constructor names and types.
* `SSHClient` still accepts `handshakeTimeout` and
  `keepAliveInterval`.
* `SSHKeyPair` still implements `SSHIdentity`.
* `SSHSession.close` is still `void`.
* `SSHKexType.dh1Sha1` still exists (Phase 6 live test).

If any of those fail, stop.

**1b. `close()` migration.** In `lib/core/ssh/ssh_client_manager.dart`,
apply only this table. Do it row by row, not as a file-wide replace.

| Line (HEAD) | Current | After | Why |
|---|---|---|---|
| 288 | `unawaited(streamFuture.then((c) => c?.close()));` | `unawaited(streamFuture.then((c) => c == null ? null : c.close()));` | Fire-and-forget of a *future* client; cannot await here. `c.close()` already returns a Future the outer `unawaited` holds. |
| 303 | same as 288 | same as 288 | same |
| 313–314 | `cmdClient.close();` / `streamClient?.close();` then `return;` | `await cmdClient.close();` / `if (streamClient != null) await streamClient.close();` then `return;` | Already `async`; discarding both new clients. Official await. |
| 324, 328 | `previousCmd?.close();` / `previousStream.close();` | `unawaited(previousCmd?.close());` / `unawaited(previousStream.close());` | Winning connect must attach immediately; do not wait on the previous session. |
| 350, 353 | `stream.close();` / `cmd.close();` in `onDead` | `unawaited(...)` | `onDead` is synchronous. |
| 390 | `stream.close();` in stream `onDead` | `unawaited(stream.close());` | same |
| 454 | `stream.close(); return;` in redial | `await stream.close(); return;` | Already `async`; discarding a superseded redial. |
| 573 | `client.close(); return null;` | `await client.close(); return null;` | `_openAuthenticatedClient` is `async`; discarding a superseded handshake. |
| 587 | `client.close(); rethrow;` | `await client.close(); rethrow;` | Auth/handshake failure; await teardown before the error propagates. |
| 595 | `client.close(); return null;` | `await client.close(); return null;` | same as 573 |
| 607 + 628–630 | pending loop + `_closeClient` | see below | User-initiated `disconnect()` is `async` — this is the README path. |

**`disconnect` / `_closeClient` (official await path).** Change
`_closeClient` to `Future<void>` and await both clients:

```dart
  Future<void> disconnect() async {
    ++_generation;
    final pending = [for (final client in _pending) client.close()];
    _pending.clear();
    await Future.wait([...pending, _closeClient()]);
  }

  Future<void> _closeClient() async {
    _health?.stop();
    _health = null;
    _streamHealth?.stop();
    _streamHealth = null;
    _redialTimer?.cancel();
    _redialTimer = null;
    _redialProfile = null;
    _redialVerify = null;
    _redialFailures = 0;
    final cmd = _client;
    final stream = _streamClient;
    _client = null;
    _streamClient = null;
    _clientGeneration = -1;
    await Future.wait([
      if (cmd != null) cmd.close(),
      if (stream != null && !identical(stream, cmd)) stream.close(),
    ]);
  }
```

Every current `_closeClient()` call site is inside an `async` method
(`connect` failure path, `disconnect`). Change those to `await _closeClient();`.
The `connect` failure path today is `if (gen == _generation) _closeClient();`
— make it `if (gen == _generation) await _closeClient();`.

Leave `ssh_command_executor.dart` `session.close()` / `s.stdin.close()`
alone (`SSHSession.close()` is still `void` in 3.3.0).

**1c. `identities:`.** Read `ssh_client_manager.dart` around the
`SSHClient(` constructor. The `identities: hasKey ? SSHKeyPair.fromPem(...)
: null` argument must be unchanged. No edit.

**1d. `handshakeTimeout`.** In that same `SSHClient(` argument list, add
one named argument immediately after `keepAliveInterval: null,`:

```dart
        keepAliveInterval: null,
        handshakeTimeout: _socketTimeout,
```

Do **not** add library `authTimeout`. The pausable wrapper stays.
`handshakeTimeout` fires `SSHHandshakeError('Handshake timed out')` on
`authenticated` if KEX has not finished (`_handleHandshakeTimeout`); our
humanize branch in Phase 2 covers that. It does **not** cover a host-key
prompt — that happens after `_transportReady`, which cancels the handshake
timer.

**1e. Gate.**

```sh
rg -n "dartssh3" pubspec.yaml pubspec.lock
flutter analyze
```

`dartssh3` must not appear. Analyze must be clean. A leftover
`client.close();` that is neither `await`ed nor wrapped in `unawaited`
fails `unawaited_futures` — that is the missed-site detector. Confirm
the Phase 1b table's await-vs-unawaited choices, not merely that analyze
is quiet. Do not proceed if analyze is dirty.

### Phase 2 — Error copy and retry policy

**2a.** Edit `lib/core/ssh/ssh_error_messages.dart`.

* Keep the existing `package:dartssh2/dartssh2.dart` import.
* Add `peerDisconnectReason` and `transportLostMessage` exactly as in
  [Architecture](#deterministic-copy).
* Insert the `SSHDisconnectError` and `SSHPacketError` branches in
  `humanizeSshError` after the `SSHChannelOpenError` branch and before
  `TimeoutException`.

**2b.** Edit `lib/core/ssh/ssh_command_executor.dart`
`isTransientTransportError` (~515-538).

* Add `e is SSHDisconnectError` and `e is SSHHandshakeError` to the first
  (never-retry) list, next to `SSHAuthError`.
* **Remove** `e is SSHPacketError` from the retry list (~535) and add it to
  the never-retry list. Malformed packets are protocol errors as of 3.3.0
  (#223), not blips.

**2c. Gate.**

```sh
flutter analyze
flutter test test/ssh_error_messages_test.dart
```

The existing three tests must still pass. New tests land in Phase 6; if you
prefer to write them in this phase, that is allowed as long as they match
Phase 6's names and oracles.

### Phase 3 — Drop path and UI

**3a. Controller.** `lib/core/providers/app_providers.dart` (edit with
awareness of the NUL-byte file; `rg -a` to locate).

Replace `_watchForDrop` / `_onTransportClosed` (~1913-1934) with:

```dart
  void _watchForDrop(int attempt) {
    final done = ref.read(sshClientManagerProvider).done;
    if (done == null) return;
    // An abrupt network loss can complete `done` with an *error* rather than
    // normally; handle both so the drop is always caught. Keep the error so
    // a peer SSH_MSG_DISCONNECT reason reaches the lost/reconnecting UI.
    done
        .then((_) => _onTransportClosed(attempt))
        .catchError((Object e) => _onTransportClosed(attempt, error: e));
  }

  void _onTransportClosed(int attempt, {Object? error}) {
    if (attempt != _attempt || !ref.mounted) return;
    if (state.phase != ConnectionPhase.connected) return; // intentional close
    state = state.copyWith(
      phase: ConnectionPhase.lost,
      error: transportLostMessage(error),
      reconnecting: true,
    );
    _autoReconnect();
  }
```

Add the `ssh_error_messages.dart` import if this library does not already
import it (it already calls `humanizeSshError` at ~1466 and ~2312, so the
import exists).

Do not change the `phase != connected` guard. User-initiated
`disconnect()` must still record nothing.

**3b. Reconnecting overlay.** `lib/features/app_shell.dart`:

* Add `final String? reason;` to `_ReconnectingOverlay`.
* Pass it from the `connection.reconnecting` call site (~1099-1106):
  `reason: connection.error`.
* In `build`, after the existing "Lost contact with $host." paragraph and
  **only when** `widget.reason != null && widget.reason != 'Connection lost'`,
  add a body-text line showing `widget.reason`. Do not change the title
  (`Connection interrupted`).

**3c. Lost landing.** `lib/features/connection/connection_landing.dart`
lost branch (~61-80). After the existing subtitle, when
`connection.error != null && connection.error != 'Connection lost'`, show
that string as a second subtitle (same gray body style). Leave the title
`Connection lost`.

**3d. Dashboard.** `lib/features/dashboard/dashboard_sheet.dart`
`_connectionCard`, after the existing reconnecting row (~174-179), when
`connection.error != null && connection.error!.isNotEmpty`, add:

```dart
        if (connection.error != null && connection.error!.isNotEmpty)
          _kvRow(typography, 'Last drop', connection.error!),
```

This does **not** invent `TransportDropSample`. It reuses `ConnectionState.error`.

**3e. Gate.**

```sh
flutter analyze
```

Must be clean. Widget tests for the overlay/landing are not required; the
string oracles live on `transportLostMessage`.

### Phase 4 — Connect diagnostics

In `_openAuthenticatedClient`, after the pausable `authenticated` await
succeeds and after the post-auth generation check (~593-597), immediately
before `return client;`:

```dart
    developer.log(
      'SSH handshake remote=${client.remoteVersion} strictKex=${client.strictKex}',
      name: 'SSHClientManager',
    );
    return client;
```

`developer` is already imported (`dart:developer` as `developer`).
`strictKex` is a 3.1.0+ getter; it compiles only after Phase 1a.

Do not change control flow based on `strictKex`. Log only.

**Gate:** `flutter analyze` clean.

### Phase 5 — Rekey re-verification and upstream

Read 3.3.0 `lib/src/ssh_transport.dart` in the pub cache.

1. Confirm `_rekeyPendingPackets` is still an unbounded `List<Uint8List>`.
2. Confirm `_shouldBypassRekeyBuffer` still lets through only message IDs
   20–49 and ≤ 4, so `SSH_MSG_GLOBAL_REQUEST` (80, used by `ping`) is
   buffered during rekey.

Write the finding as a short comment in this plan's "Confirmation log"
section at the bottom (append; do not rewrite history), with the 3.3.0
line numbers you actually saw.

If still unbounded: file one upstream issue on
`https://github.com/vicajilau/dartssh2` titled approximately "Bound
`_rekeyPendingPackets` during rekey (fail the connection instead of
buffering forever)" and reference PR #125's own caveat plus our
observation that pings (msg 80) stall. Paste the issue URL into the
Confirmation log.

If 3.3.0 **did** bound the list: stop and report — that is a MADR 0011
assumption change, not a silent win to fold into this diff.

Optional second issue (only if `SSHSocket.connect` still has no TCP
keepalive argument): request `SocketOption.tcpKeepAlive` exposure. Do not
block the phase on it.

**Gate:** Confirmation log filled. No Dart change required in this phase
unless the finding contradicts 0011, in which case stop.

### Phase 6 — Tests

Add or extend tests. Do not weaken existing assertions.

**6a. `test/ssh_error_messages_test.dart`**

Add, using the 3.3.0 constructor confirmed against tag `v3.3.0`
(`SSHDisconnectError(int reasonCode, String message)`). Reason **3** is
IANA/`RFC 4253` `SSH_DISCONNECT_KEY_EXCHANGE_FAILED` — the code OpenSSH
sends with the changelog's example description. Do not use 11
(`BY_APPLICATION`).

```dart
  test('humanizeSshError maps SSHDisconnectError', () {
    expect(
      humanizeSshError(SSHDisconnectError(3, 'no matching key exchange method found')),
      'The host closed the connection (3: no matching key exchange method found).',
    );
  });

  test('humanizeSshError unwraps SSHAuthAbortError.reason', () {
    expect(
      humanizeSshError(SSHAuthAbortError(
        'Connection closed before authentication',
        SSHDisconnectError(3, 'no matching key exchange method found'),
      )),
      'The host closed the connection (3: no matching key exchange method found).',
    );
  });

  test('humanizeSshError maps SSHHandshakeError', () {
    expect(
      humanizeSshError(SSHHandshakeError('Handshake timed out')),
      'Timed out during the SSH handshake.',
    );
  });

  test('humanizeSshError maps SSHPacketError', () {
    expect(
      humanizeSshError(SSHPacketError('truncated')),
      'The SSH session received a malformed packet.',
    );
  });

  test('peerDisconnectReason and transportLostMessage', () {
    expect(peerDisconnectReason(Exception('x')), isNull);
    expect(transportLostMessage(null), 'Connection lost');
    expect(transportLostMessage(Exception('x')), 'Connection lost');
    final err = SSHDisconnectError(3, 'no matching key exchange method found');
    expect(peerDisconnectReason(err), '3: no matching key exchange method found');
    expect(
      transportLostMessage(err),
      'Connection lost (3: no matching key exchange method found)',
    );
    expect(
      peerDisconnectReason(SSHAuthAbortError('Connection closed before authentication', err)),
      '3: no matching key exchange method found',
    );
  });
```

Import `package:dartssh2/dartssh2.dart` in this test file (today it is not;
it only imports our wrappers).

**6b. Transient policy.** `SSHCommandExecutor.isTransientTransportError` is
already public and tested in `test/ssh_command_executor_test.dart` (group
`isTransientTransportError / runWithRetries`, ~193). Add one sibling test
in that group (the file already imports dartssh2):

```dart
    test('never retries peer disconnect, handshake timeout, or malformed packet', () {
      expect(
        SSHCommandExecutor.isTransientTransportError(
          SSHDisconnectError(3, 'no matching key exchange method found'),
        ),
        isFalse,
      );
      expect(
        SSHCommandExecutor.isTransientTransportError(
          SSHHandshakeError('Handshake timed out'),
        ),
        isFalse,
      );
      expect(
        SSHCommandExecutor.isTransientTransportError(
          SSHPacketError('truncated'),
        ),
        isFalse,
      );
    });
```

The existing `retries connection-closed style transport blips` test
(`Exception('SSH connection closed by peer')`) stays `isTrue` — that is a
string fallback, not a typed `SSHDisconnectError`.

**6c. Live suite — regression.** Existing
`test/ssh_live_transport_test.dart` tests must pass unchanged against
3.3.0. That is the AES-GCM / strict-kex interop proof: `_DisposableSshd`
is stock OpenSSH on loopback.

**6d. Live suite — peer disconnect reason.** Add one `integration`-tagged
test to `test/ssh_live_transport_test.dart`. Do **not** go through
`SSHClientManager` (it does not expose `algorithms`). Talk dartssh2
directly.

Pre-auth peer `SSH_MSG_DISCONNECT` does **not** land on `authenticated` as
a raw `SSHDisconnectError`. 3.3.0 `_handleTransportClosed` wraps it:

`SSHAuthAbortError('Connection closed before authentication', <SSHDisconnectError>)`.

The test must unwrap `reason`. Mid-session drops (Phase 3) still see the
raw type on `SSHClient.done`.

1. Add to `_DisposableSshd`'s `sshd_config` template, after
   `PubkeyAuthentication yes`. Include **both** curve25519 spellings —
   official `SSHKexType.x25519Rfc` docs: OpenSSH matches names literally
   and a server that only has one spelling will reject the other with
   `"no matching key exchange method found"`:

   ```
   KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,ecdh-sha2-nistp256,ecdh-sha2-nistp384,ecdh-sha2-nistp521,diffie-hellman-group14-sha256,diffie-hellman-group-exchange-sha256
   ```

   This excludes `diffie-hellman-group1-sha1`. Existing tests must still
   connect (3.3.0 defaults lead with curve25519 and advertise both names
   since 2.22.4).

2. New test, skip when `sshd == null`. Pass `onVerifyHostKey` (README:
   omitting it accepts every host key — fine for this loopback test, but
   we pass an accept-all handler so the test does not depend on that
   default). Do **not** pass `disableHostkeyVerification: true`.

   ```dart
   test('peer rejects non-overlapping kex with SSHDisconnectError', () async {
     if (skip()) return;
     final socket = await SSHSocket.connect('127.0.0.1', sshd!.port);
     final client = SSHClient(
       socket,
       username: sshd!.profile.username,
       identities: SSHKeyPair.fromPem(sshd!.privateKeyPem),
       algorithms: const SSHAlgorithms(kex: [SSHKexType.dh1Sha1]),
       onVerifyHostKey: (_, _) => true,
     );
     try {
       await client.authenticated;
       fail('expected the server to disconnect');
     } catch (e) {
       expect(e, isA<SSHAuthAbortError>());
       final reason = (e as SSHAuthAbortError).reason;
       expect(reason, isA<SSHDisconnectError>());
       expect(peerDisconnectReason(e), isNotNull);
       expect(humanizeSshError(e), startsWith('The host closed the connection'));
     } finally {
       await client.close();
     }
   });
   ```

   Import `package:dartssh2/dartssh2.dart` and
   `ssh_error_messages.dart`. If this test fails because this OpenSSH still
   accepts group1 despite the config line, stop and record `sshd -V` plus
   `sshd -T -f <config> | rg kex` in the Confirmation log; do not delete
   the test to go green — fix the config.

   If `authenticated` throws a raw `SSHDisconnectError` (library changed
   the wrap), accept that too — assert `peerDisconnectReason(e) != null`
   as the real oracle and note the wrap change in the Confirmation log.

**6e. Hardening regression.**

```sh
flutter test test/ssh_transport_hardening_test.dart
```

Must stay green (parallel handshake, verifier serialization, disconnect
force-close, redial backoff, upload timeout). Constructor gained
`handshakeTimeout`; that must not break the stalled-server tests.

**6f. Full suite gate.**

```sh
flutter analyze
flutter test test/ssh_error_messages_test.dart
flutter test test/ssh_transport_hardening_test.dart
flutter test test/ssh_live_transport_test.dart
flutter test
```

All must be clean. `flutter test` includes `integration`-tagged tests and
takes minutes. Do not run `live-forge`.

### Phase 7 — Docs only

1. `docs/ARCHITECTURE_PLAN.md` §0.1: change any "dartssh2 2.21.1 / 2.22.5"
   pin wording that describes the *current* library to **3.3.0**. Leave
   historical spike notes that say 2.21.1 as history. Add one sentence:
   we stay on the `dartssh2` package; the `dartssh3` pub package is a
   stale fork and is not a dependency. Point at this MADR.
2. `docs/0013-MADR-prefer-dartssh2-v3-over-dartssh3.md`: already points
   at this file (applied when the plan was first written). Verify the
   link is still present; do not rewrite the decision.
3. `docs/0012-PLAN-adopt-dartssh2-v3.md`: already has the "do not execute"
   banner. Verify it is still present.

**Gate:** docs-only diff. No Dart.

## Verification

Acceptance is all of the following. Each maps to a command or a readable
artifact.

| # | Criterion | Proof |
|---|---|---|
| 1 | No `dartssh3` dependency or import | `rg -n dartssh3 pubspec.yaml pubspec.lock lib test` is empty |
| 2 | Lock is exact 3.3.0 | `pubspec.yaml` has `dartssh2: 3.3.0`; `pubspec.lock` `version: "3.3.0"` |
| 3 | Analyze clean after `close()` migration (await on async teardown, `unawaited` only on sync/`onDead`/winning-attach) | `flutter analyze` + table review |
| 4 | `identities:` unchanged | diff shows no edit at that argument |
| 5 | `keepAliveInterval: null` still set; no `disableHostkeyVerification`; no library `authTimeout` | `rg` on `ssh_client_manager.dart` |
| 6 | `handshakeTimeout: _socketTimeout` present | same |
| 7 | Humanize oracles | `flutter test test/ssh_error_messages_test.dart` |
| 8 | Disconnect is not retried | Phase 6b test |
| 9 | Live interop + peer kex reject | `flutter test test/ssh_live_transport_test.dart` |
| 10 | Hardening suite | `flutter test test/ssh_transport_hardening_test.dart` |
| 11 | Full suite | `flutter test` |
| 12 | Drop UI has a reason string | `_onTransportClosed` uses `transportLostMessage`; overlay and landing read `connection.error` |
| 13 | Rekey finding recorded | Confirmation log at the bottom of this file |
| 14 | 0011 not silently implemented | `command_telemetry.dart` still has no `TransportDropSample` unless 0011 was executed as its own plan |

Manual soak (after the automated gate, on a real remote the maintainer
already uses): connect, run a fetch, then force a server-side disconnect
(`sshd` restart or `ClientAliveCountMax` kill). Confirm the reconnecting
overlay shows `Connection lost (3: …)` (or whatever RFC 4253 code the
peer sent) rather than a bare "The SSH connection dropped." If the peer
only RSTs, the overlay stays generic — that is acceptable; the kex-reject
live test is the typed-error proof.

## Rollout and Rollback

**Rollout.** One dependency bump, same process, no persisted schema, no
bookmark/Keychain migration, no wire-format change of our own. 3.3.0
changes the *default negotiated cipher* to AES-GCM (then ChaCha20). Stock
OpenSSH accepts that. A remote that offers only 3des/arcfour would fail
handshake; we do not support those and must not re-enable them to paper
over it.

**Rollback.** Reverse `pubspec.yaml` to `dartssh2: ^2.22.5`, run
`flutter pub get`, revert the Dart/UI/test/docs commits for this plan.
2.22.5 `close()` is `void`, so both `await client.close()` and
`unawaited(client.close())` become analyze errors. Rollback must revert
the close-site edits together with the pin. No data migration to undo.

**Pin policy after landing.** Stay on exact `3.3.0` until a later 3.x has
passed `test/ssh_live_transport_test.dart` on this app. Do not silently
move to `^3.3.0`.

## Task Checklist

### Phase 0
- [ ] HEAD facts match this plan (or the plan was updated first)

### Phase 1
- [ ] `pubspec.yaml`: `dartssh2: 3.3.0` exact
- [ ] `flutter pub get`; lock is 3.3.0; no `dartssh3`
- [ ] 3.3.0 source facts recorded (`close`, `SSHDisconnectError`, `dh1Sha1`)
- [ ] `close()` sites migrated per table (await vs unawaited)
- [ ] `disconnect` / `_closeClient` await teardown
- [ ] `identities:` untouched
- [ ] `handshakeTimeout: _socketTimeout` added; no library `authTimeout`
- [ ] `flutter analyze` clean

### Phase 2
- [ ] `peerDisconnectReason` unwraps `SSHAuthAbortError.reason`
- [ ] `transportLostMessage`
- [ ] `humanizeSshError` branches (disconnect, abort-unwrap, handshake, packet)
- [ ] `SSHDisconnectError` / `SSHHandshakeError` / `SSHPacketError` never-retry
- [ ] `flutter analyze` clean

### Phase 3
- [ ] `_watchForDrop` keeps the error
- [ ] `_onTransportClosed` uses `transportLostMessage`
- [ ] overlay + landing + dashboard show non-generic reason
- [ ] `flutter analyze` clean

### Phase 4
- [ ] `strictKex` / `remoteVersion` log after auth
- [ ] `flutter analyze` clean

### Phase 5
- [ ] `_rekeyPendingPackets` re-read in 3.3.0
- [ ] Confirmation log appended
- [ ] Upstream issue filed if still unbounded

### Phase 6
- [ ] `ssh_error_messages_test.dart` new cases
- [ ] transient-policy test
- [ ] live sshd `KexAlgorithms` line
- [ ] live kex-reject test
- [ ] `flutter test test/ssh_live_transport_test.dart`
- [ ] `flutter test test/ssh_transport_hardening_test.dart`
- [ ] `flutter test` full suite

### Phase 7
- [ ] `ARCHITECTURE_PLAN.md` §0.1 pin + dartssh3 warning
- [ ] 0013 MADR points at this plan
- [ ] 0012-PLAN banner

## Confirmation log

Filled 2026-08-19 during execution.

* 3.3.0 cache path: `/Users/saxsmith/.pub-cache/hosted/pub.dev/dartssh2-3.3.0`
* `SSHClient.close` signature: `Future<void> close() async`
* `SSHDisconnectError` constructor: `SSHDisconnectError(this.reasonCode, this.message)` (`int`, `String`)
* Pre-auth wrap still `SSHAuthAbortError(..., reason)`? yes (`_handleTransportClosed`)
* `SSHKexType.dh1Sha1` present: yes (`lib/src/algorithm/ssh_kex_type.dart`)
* `_rekeyPendingPackets` still unbounded? yes — `List<Uint8List>` at `ssh_transport.dart:343`, append `:356-357`, flush `:1825-1826`
* `_shouldBypassRekeyBuffer` IDs: `messageId >= 20 && messageId <= 49 || messageId <= 4` (`:1868-1872`). `SSH_MSG_GLOBAL_REQUEST` (80) still buffered.
* Upstream issue URL: not filed — no authenticated write access to `vicajilau/dartssh2` from this session. Finding stands; file from a maintainer account.
* Live kex-reject (Phase 6d): `authenticated` completed with `SSHAuthAbortError` whose `reason` is `SSHInternalError(Bad state: No matching key exchange algorithm)`, not `SSHDisconnectError`. dartssh2 chooses the algorithm locally after both KEXINITs and fails before a peer `SSH_MSG_DISCONNECT` is observed. Test accepts that wrap; typed `SSHDisconnectError` mapping remains unit-tested.
