---
status: "executed"
date: 2026-08-18
associated-madr: "0012-MADR-adopt-dartssh2-v3.md"
owner: [Maintainer]
target-milestone: Next work cycle (post-review)
verified: 2026-08-20
---

# Plan: Adopt dartssh2 3.3.0 (migration + disconnect-reason telemetry)

> **Execution note (2026-08-19).** Do not execute this plan. The review and
> execution vehicle is
> [0013-PLAN-prefer-dartssh2-v3-over-dartssh3.md](./0013-PLAN-prefer-dartssh2-v3-over-dartssh3.md),
> which absorbs this bump and extends it. This file remains the 0012-era
> draft.

## Executive Summary & Goal

Companion to [0012-MADR-adopt-dartssh2-v3.md](./0012-MADR-adopt-dartssh2-v3.md).

**Goal.** Upgrade the pinned `dartssh2` from `^2.22.5` (locked 2.22.5) to the
exact version **`3.3.0`** (not a caret range — per the MADR's churn-risk
mitigation), absorb the two breaking changes mechanically, and wire the new
`SSHDisconnectError` into the drop-cause telemetry so peer disconnect reasons
reach the caller and the dashboard.

**Scope.** This plan is deliberately narrow: (1) the dependency bump, (2) the
`close()` migration, (3) the `SSHDisconnectError` telemetry wiring, (4) rekey
re-verification and the upstream issue. It does **not** adopt `SSHIdentity`/
Secure Enclave (deferred — its own decision) and does **not** re-architect the
transport (MADR 0011 owns that).

**Acceptance criteria.**

1. `flutter analyze` clean after migrating every `SSHClient.close()` call site
   and confirming the `identities:` site compiles unchanged.
2. `flutter test test/ssh_live_transport_test.dart` green against 3.3.0 (real
   loopback sshd): connect, execute, compressed read, timeout-kill, in-flight
   disconnect supersession, executor-seam parity.
3. `flutter test` full suite green, including `ssh_transport_hardening_test.dart`.
4. A peer `SSH_MSG_DISCONNECT` reason is captured and recorded into
   `CommandTelemetry`'s `TransportDropSample` (unit-proven), and the dashboard
   shows it.
5. Rekey-buffer behavior re-verified against 3.3.0 source; upstream issue filed
   or confirmed still open.

## Prerequisites & Dependencies

- **Toolchain**: Flutter SDK per `pubspec.yaml`; commands `flutter pub get`,
  `flutter analyze`, `flutter test` (see `AGENTS.md`).
- **Dependency**: `dartssh2` 3.3.0. All API facts below verified against the
  3.3.0 source in the pub cache (`/data/cache/pub/hosted/pub.dev/dartssh2-3.3.0`).
- **Sequencing dependency on MADR 0011**: the `TransportDropSample` /
  `TransportDropCause` telemetry this plan extends is introduced by
  `0011-PLAN-ssh-transport-stability-hardening.md`. Land 0011's Phase 1
  (telemetry foundation) first, or land them together; the `peerReason` field
  added here is additive to 0011's `TransportDropSample`.
- **No new packages.** `SSHDisconnectError` is exported from
  `package:dartssh2/dartssh2.dart` (verified: `lib/dartssh2.dart:4` exports
  `src/ssh_errors.dart`), already imported by the SSH layer.

## Architecture & Technical Design Overview

### Verified 3.3.0 API diff (grounded in pub-cache source)

| Symbol | 2.22.5 | 3.3.0 | Impact |
|---|---|---|---|
| `SSHClient.close()` | `void` | `Future<void>` (`ssh_client.dart:770`) | **Breaking** — 16 call sites |
| `SSHSession.close()` | `void` | `void` (`ssh_session.dart:119`) | Unchanged — our `session.close()` sites unaffected |
| `SSHChannel.close()` | — | `Future<void>` (`ssh_channel.dart:232`) | Not called by us |
| `SftpClient.close()` | `Future<void>` | `Future<void>` (`sftp_client.dart:261`) | Unchanged (was `Future` since 2.22.3); not called by us |
| `SSHClient.identities` | `List<SSHKeyPair>?` | `List<SSHIdentity>?` (`ssh_client.dart:152`) | **Source-compatible** — `SSHKeyPair implements SSHIdentity` (`ssh_key_pair.dart:18`); `fromPem` returns `List<SSHKeyPair>` (`ssh_key_pair.dart:26`) |
| `SSHDisconnectError` | absent | `SSHDisconnectError(this.reasonCode, this.message)` (`ssh_errors.dart:70-77`); `reasonCode` is `int`, `message` is `String` | New — feed telemetry |

**Disconnect surfacing path (verified):** the transport's
`SSH_Message_Disconnect` handler calls
`closeWithError(SSHDisconnectError(reasonCode, description))`
(`ssh_transport.dart:1433-1444`) → `_doneCompleter.completeError(...)`
(`ssh_transport.dart:588`) → `SSHClient.done` (`ssh_client.dart:220`) completes
with the error. Our existing `_watchForDrop` already routes error completion
to `_onTransportClosed`, so `SSHDisconnectError` arrives on the path we must
extend.

**`close()` semantics change (verified, `ssh_client.dart:770-776`):** 3.3.0
`close()` now cancels timers, terminates pending operations with
`SSHStateError('SSH client closed')`, closes channels, and `await`s
`_transport.close()`. Wrapping in `unawaited(...)` preserves our current
fire-and-forget semantics exactly (initiate teardown, don't wait).

### Migration surface (verified against our code)

All 16 `SSHClient.close()` call sites live in
`lib/core/ssh/ssh_client_manager.dart`. `lib/core/ssh/ssh_command_executor.dart`
has **zero** affected sites (`session.close()` is `SSHSession`, unchanged;
`s.stdin.close()` is a stream sink). The `identities:` site
(`ssh_client_manager.dart:546-547`) needs no change.

### Deterministic migration rule

`dart:async`'s `unawaited(Future<void>?)` accepts the nullable future, so:

- Statement-position `X.close();` → `unawaited(X.close());`
- Nullable `X?.close();` → `unawaited(X?.close());`
- `.then((c) => c?.close())` → `.then((c) => unawaited(c?.close()))`

This preserves fire-and-forget semantics and satisfies `unawaited_futures`.
No call site changes from fire-and-forget to awaited; no reordering.

## Phased Execution Plan

### Phase 1 — Dependency bump + mechanical migration

1. `pubspec.yaml`: `dartssh2: ^2.22.5` → `dartssh2: 3.3.0` (exact pin, no caret).
   Run `flutter pub get`; confirm `pubspec.lock` resolves `3.3.0`.
2. Migrate the 16 `close()` sites in `ssh_client_manager.dart` per the rule
   above. Exact sites (current line numbers):

   | Line | Current | After |
   |---|---|---|
   | 288 | `unawaited(streamFuture.then((c) => c?.close()));` | `unawaited(streamFuture.then((c) => unawaited(c?.close())));` |
   | 303 | `unawaited(streamFuture.then((c) => c?.close()));` | `unawaited(streamFuture.then((c) => unawaited(c?.close())));` |
   | 313 | `cmdClient.close();` | `unawaited(cmdClient.close());` |
   | 314 | `streamClient?.close();` | `unawaited(streamClient?.close());` |
   | 324 | `previousCmd?.close();` | `unawaited(previousCmd?.close());` |
   | 328 | `previousStream.close();` | `unawaited(previousStream.close());` |
   | 350 | `stream.close();` | `unawaited(stream.close());` |
   | 353 | `cmd.close();` | `unawaited(cmd.close());` |
   | 390 | `stream.close();` | `unawaited(stream.close());` |
   | 454 | `stream.close();` | `unawaited(stream.close());` |
   | 573 | `client.close();` | `unawaited(client.close());` |
   | 587 | `client.close();` | `unawaited(client.close());` |
   | 595 | `client.close();` | `unawaited(client.close());` |
   | 607 | `client.close();` | `unawaited(client.close());` |
   | 628 | `cmd?.close();` | `unawaited(cmd?.close());` |
   | 630 | `stream.close();` | `unawaited(stream.close());` |

   Review each site by hand — this is the generation-pinning safety-critical
   file; do not bulk-replace.
3. Confirm the `identities:` site (`ssh_client_manager.dart:546-547`) compiles
   unchanged (no edit expected).
4. `flutter analyze` — must be clean (this is the migration's gate; a
   `unawaited_futures` or type error pinpoints any missed site).

### Phase 2 — `SSHDisconnectError` telemetry wiring

Builds on 0011's telemetry. If 0011 Phase 1 is not yet landed, land it first.

1. `lib/core/exec/command_telemetry.dart`: add `final String? peerReason;` to
   `TransportDropSample` (nullable — only `transportError`/`remoteClosed`
   causes carry it; `monitor` cause leaves it null).
2. `lib/core/providers/app_providers.dart` — extend the drop path (0011's
   split of `_watchForDrop`):

   ```dart
   done
       .then((_) => _onTransportClosed(attempt, transportError: false))
       .catchError((Object e) =>
           _onTransportClosed(attempt, transportError: true, error: e));
   ```

   In `_onTransportClosed`, extract the peer reason before recording:

   ```dart
   String? peerReason;
   if (error is SSHDisconnectError) {
     peerReason = '${error.reasonCode}: ${error.message}';
   }
   ```

   and pass `peerReason` into the `TransportDropSample` (with the existing
   `lastDropCause` dedup so a monitor kill is not double-recorded).
3. `lib/features/dashboard/dashboard_sheet.dart`: render `peerReason` in the
   last-drop row (e.g. `last drop: transport (peer: 11: no matching key
   exchange method found)`), so the reason is visible without the Output log.
4. Import `SSHDisconnectError` where needed (already available via the existing
   `package:dartssh2/dartssh2.dart` import).

### Phase 3 — Rekey re-verification + upstream

1. Verify against 3.3.0 source (already confirmed, re-confirm at migration
   time): `_rekeyPendingPackets` is still an **unbounded** `List<Uint8List>`
   (`ssh_transport.dart:343,356-357`) and `_shouldBypassRekeyBuffer` is
   unchanged (`:1868-1873` — only message IDs 20–49 and ≤ 4 bypass;
   `SSH_MSG_GLOBAL_REQUEST` = 80 is still buffered). Conclusion: the 3.x
   upgrade does **not** fix the rekey stall MADR 0011 flagged; the busy-pause
   mitigation remains necessary and the upstream issue stands.
2. File the upstream issue on `github.com/vicajilau/dartssh2`: bound
   `_rekeyPendingPackets` (size/time limit; fail the connection rather than
   buffer unbounded — the PR #125 author's own caveat). Reference our finding.
3. Optionally file the TCP-keepalive issue (from 0011) against the new repo if
   still absent in 3.3.0 (`SSHSocket.connect` still takes only `timeout`).

### Phase 4 — Verification & soak

1. Run the live suite and full suite (below).
2. Manual soak: connect to a real remote, run fetch/pull/push, and — to
   exercise the new telemetry — deliberately trigger a peer disconnect (e.g.
   `sshd -k` or a server-side `ClientAliveCountMax` kill) and confirm the
   dashboard shows the peer reason string, not a bare "Connection lost".

## Verification & Testing Strategy

- **Static**: `flutter analyze` clean (the migration gate).
- **Live integration** (`test/ssh_live_transport_test.dart`, real sshd):
  existing tests must pass against 3.3.0 unchanged. Add one test:
  `a peer disconnect surfaces SSHDisconnectError's reason` — start sshd,
  connect, then kill sshd with a reason (or send `SSH_MSG_DISCONNECT` via a
  tiny in-test server); assert `manager.done` completes with
  `SSHDisconnectError` and the telemetry sample carries the reason.
- **Unit** (`test/ssh_transport_hardening_test.dart`): a pure test that
  `_onTransportClosed`/the drop recorder maps an `SSHDisconnectError` to
  `peerReason` (extract the mapping into a testable helper if it is not
  already pure).
- **Full suite**: `flutter test` green (includes `integration`-tagged tests).
- **Regression pin**: `ssh_transport_hardening_test.dart` (parallel handshake,
  verifier serialization, disconnect force-close, redial backoff, upload
  timeout) and `ssh_live_transport_test.dart` (malformed UTF-8, timeout-kill,
  compressed read, supersession, seam parity) must pass unchanged.

## Rollback & Mitigation Procedures

**Rollback is a one-line revert.** `dartssh2: 3.3.0` → `dartssh2: ^2.22.5` and
`git revert` the `close()` migration + telemetry wiring. No persisted state, no
schema change, no wire-format change. The telemetry `peerReason` field is
additive and null-safe.

**Risk mitigations:**

| Risk | Mitigation |
|---|---|
| A missed `close()` site silently leaks a client past disconnect (the bug generation pinning prevents) | `flutter analyze` + `unawaited_futures` lint catches every un-awaited `Future<void> close()`; the 16 sites are enumerated and hand-reviewed, not bulk-edited |
| `close()` now async changes teardown timing | `unawaited(...)` preserves fire-and-forget semantics exactly; no site becomes awaited |
| `identities` type change breaks the constructor | Verified source-compatible (`SSHKeyPair implements SSHIdentity`); `flutter analyze` confirms |
| 3.3.0 is young / new maintainer | Exact pin (no caret); live-sshd suite; soak before declaring done |
| `SSHDisconnectError` double-counted with the monitor-kill path | Existing `lastDropCause` dedup from 0011 applies unchanged |
| Rekey stall assumed fixed by the upgrade | Phase 3 explicitly re-verifies it is **not** fixed; busy-pause (0011) stays the mitigation |

## Task Checklist

### Phase 1 — bump + migrate
- [ ] `pubspec.yaml`: `dartssh2: 3.3.0` (exact); `flutter pub get`; lock resolves 3.3.0
- [ ] Migrate 16 `SSHClient.close()` sites in `ssh_client_manager.dart` (lines 288–630) per the table
- [ ] Confirm `identities:` site (546-547) unchanged
- [ ] `flutter analyze` clean

### Phase 2 — disconnect-reason telemetry
- [ ] `command_telemetry.dart`: add `peerReason` to `TransportDropSample`
- [ ] `app_providers.dart`: split `_watchForDrop`; extract `SSHDisconnectError` reason in `_onTransportClosed`
- [ ] `dashboard_sheet.dart`: render `peerReason` in the last-drop row
- [ ] Unit test: `SSHDisconnectError` → `peerReason` mapping

### Phase 3 — rekey + upstream
- [ ] Re-verify `_rekeyPendingPackets` unbounded in 3.3.0 (confirm not fixed)
- [ ] File upstream issue: bound `_rekeyPendingPackets`
- [ ] File upstream issue: TCP keepalive option (if still absent)

### Phase 4 — verification
- [ ] Live test: peer disconnect surfaces `SSHDisconnectError` reason
- [ ] `flutter test test/ssh_live_transport_test.dart` green
- [ ] `flutter test` full suite green
- [ ] Manual soak: peer-disconnect reason visible on dashboard
