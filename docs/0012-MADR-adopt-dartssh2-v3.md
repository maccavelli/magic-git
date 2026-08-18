---
status: "proposed"
date: 2026-08-18
decision-makers: [Maintainer]
consulted: []
informed: [Magic Git contributors]
---

# Adopt dartssh2 3.x (pin 3.3.0) for transport hardening and disconnect diagnostics

## Context and Problem Statement

Magic Git pins `dartssh2 ^2.22.5` (locked 2.22.5) for all SSH transport. The
package recently moved maintainers — from TerminalStudio to
`github.com/vicajilau/dartssh2` (pub.dev verified publisher
`victorcarreras.dev`) — and a 3.x line was published (3.0.0 → 3.3.0, 2026-08-16
to 2026-08-18). We must decide whether to stay on 2.22.5 or adopt 3.x, and
whether the new maintainer and the rapid 3.x churn make the upgrade a net
benefit or a risk. This decision is directly coupled to the in-flight
transport-stability work (MADR 0011): the 3.x line ships `SSHDisconnectError`
and hang-forever fixes that would materially improve our ability to diagnose
the fetch/pull/push disconnect bug.

## Decision Drivers

- **Disconnect diagnosability**: the active bug (MADR 0011) is a disconnect
  whose *cause* we currently cannot attribute — the transport logs
  `SSH_MSG_DISCONNECT` and closes cleanly. 3.3.0 surfaces that reason to the
  caller.
- **Security posture**: the 3.x line adds strict key exchange (Terrapin
  mitigation), AES-GCM/ChaCha20-Poly1305 defaults, and `Random.secure()`
  throughout — all relevant to a client that moves credentials and pack data
  over untrusted links.
- **Maintenance health**: a dependency is only as safe as its maintainer; the
  fork must be assessed, not assumed.
- **Migration cost**: breaking changes must be small enough to absorb without
  destabilizing the safety-critical `ssh_client_manager.dart`.
- **Stability**: six 3.x releases in ~48 hours is both a signal of active
  maintenance and a churn risk; the pin must bound that risk.

## Considered Options

1. **Adopt 3.x now, pin 3.3.0** — migrate the breaking changes, feed
   `SSHDisconnectError` into the MADR 0011 drop-cause telemetry, and land the
   security hardening.
2. **Stay on 2.22.5** — accept the security/feature gap and diagnose
   disconnects without the peer's reason string.
3. **Adopt 3.x later (deferred)** — finish MADR 0011 on 2.22.5 first, then
   upgrade as a separate, sequenced decision.
4. **Fork/vendor 2.22.5** — take ownership of the transport ourselves.

## Decision Outcome

Chosen option: **"Adopt 3.x now, pin 3.3.0"**, because the immediate value
(peer disconnect reason + hang-forever fixes + strict-kex/AES-GCM/secure-random
hardening) directly addresses the active disconnect investigation and the
migration cost is small and mechanical, while the maintenance health signal is
strong enough to accept the fork. The pin is to the exact version `3.3.0`
(not a caret range) to bound the churn risk, and the upgrade is sequenced to
land with the MADR 0011 telemetry so `SSHDisconnectError` feeds drop-cause
attribution from day one.

### Maintenance assessment (grounded)

- **Continuity, not takeover**: `vicajilau` was already the top contributor to
  the TerminalStudio repo (207 commits vs. `xtyxtyx` 162, `GreenAppers` 51)
  and authored most of the 2.15→2.22 hardening releases. The fork is the
  existing primary maintainer relocating the repo, not an unknown party.
- **Ecosystem upstreaming**: `GT-610` (8 commits, all security/hardening) is
  upstreaming fixes "from ServerBox's fork" — ServerBox is the largest
  production consumer of dartssh2. A major downstream feeding fixes upstream
  is a strong health signal.
- **Process hygiene**: `SECURITY.md` (private vulnerability reporting, added
  3.1.0), GitHub Actions CI, `codecov.yml`, 0 open issues / 0 open PRs at the
  time of writing, MIT license, pub.dev verified publisher, 71.6k downloads.
- **Churn risk (the honest caveat)**: 3.0.0→3.3.0 landed in ~48 hours. This is
  a focused hardening sprint (the changelog entries are coherent and
  test-backed), but it means 3.x has not yet accumulated weeks of field
  exposure. Pinning `3.3.0` and relying on our live-sshd test suite
  (`test/ssh_live_transport_test.dart`) is the mitigation.

### Immediate-value features (grounded in the 3.x changelog)

| Feature | Version | Value to Magic Git |
|---|---|---|
| `SSHDisconnectError` — peer `SSH_MSG_DISCONNECT` reason reaches caller | 3.3.0 | **High.** Feeds MADR 0011 drop-cause telemetry; turns "it disconnected" into "server said: no matching key exchange method" |
| Hang-forever fixes — global request / channel open whose reply can never arrive now fails with the connection's error | 3.1.0 (#212/#210) | **High.** The ping-starvation / dead-NAT path in MADR 0011 |
| Strict key exchange (`kex-strict-c-v00@openssh.com`, Terrapin CVE-2023-48795) + `SSHClient.strictKex` | 3.1.0 (#207) | **High.** Security; also touches rekey handling |
| AES-GCM promoted to default cipher; ChaCha20-Poly1305 added; broken algorithms (dh-group1-sha1, hmac-md5, truncated hmac) removed from defaults | 3.1.0 / 3.2.0 | **High.** Security + interop |
| `Random.secure()` for all protocol randomness | 3.0.1 (#193) | **High.** Security |
| `SSH_MSG_UNIMPLEMENTED` handling (RFC 4253) — no reply loops | 3.2.0 (#216) | Medium. Protocol correctness |
| SFTP 256 KiB packet cap (OpenSSH `SFTP_MAX_MSG_LENGTH`) | 3.2.0 (#215) | Medium. DoS hardening |
| SFTP read data-loss fix + pipelined reads | 3.0.2 (#200) | Medium. Correctness (we use exec-channel upload, not SFTP, but reads matter) |
| `SSHIdentity` external signers (Secure Enclave, YubiKey/FIDO2, smart cards, OS agents) + RFC 4252 §7.8 probing | 3.0.0 (#190) | **Future.** Enables moving macOS key material into the Secure Enclave; requires separate integration work |
| Hostbased auth (RFC 4252 §9) | 3.2.0 (#218) | Low. Rarely used by our remotes |

### Migration cost (grounded in our codebase)

- **`SSHClient.close()`: `void` → `Future<void>`** (3.0.0 breaking). Our
  `lib/core/ssh/` layer has ~16 `SSHClient.close()` call sites, concentrated
  in `ssh_client_manager.dart` (lines 288, 303, 313, 314, 324, 328, 350, 353,
  390, 454, 573, 587, 595, 607, 628, 630). Each becomes an `unawaited(...)`
  (or an awaited teardown where ordering matters) under the repo's
  `unawaited_futures` lint. Mechanical, but it is the safety-critical file —
  the migration must be reviewed line-by-line, not bulk-edited.
- **`SSHClient.identities` getter: `List<SSHKeyPair>?` → `List<SSHIdentity>?`**
  (3.0.0 breaking). One construction site
  (`ssh_client_manager.dart:546-547`, `SSHKeyPair.fromPem(...)`) — the
  changelog states `List<SSHKeyPair>` constructor invocations remain 100%
  source-compatible.
- **Min Dart SDK 3.0** — already satisfied.
- `SSHSession.close()` and `SftpClient.close()` are unchanged by 3.0.0
  (`SftpClient.close()` became `Future<void>` back in 2.22.3, already in our
  pin).

### Sequencing

Land this upgrade in the same work cycle as MADR 0011's drop-cause telemetry,
so `SSHDisconnectError` is wired into `CommandTelemetry`'s
`TransportDropSample` from the start rather than retrofitted. The 3.x rekey
work (#207 strict kex) may alter the rekey-buffering behavior MADR 0011
flagged — re-verify the `_rekeyPendingPackets` behavior against 3.3.0 source
as part of the migration (the upstream issue remains open if still unbounded).

* Implementation Plan: to be written once this decision is accepted
  (`0012-PLAN-adopt-dartssh2-v3.md`).

## Consequences

- Good, because disconnects become attributable: the peer's reason string feeds
  the drop-cause telemetry and directly accelerates the MADR 0011 investigation.
- Good, because we inherit strict-kex, AES-GCM/ChaCha20 defaults, and
  `Random.secure()` — material security hardening for a credential-moving
  client, at no design cost.
- Good, because the hang-forever fixes (#212/#210) independently reduce the
  exact dead-NAT failure mode MADR 0011 targets.
- Bad, because we accept a 2-day-old major line with a relocated maintainer;
  the churn risk is real and is only bounded by pinning `3.3.0` and our
  live-sshd tests, not eliminated.
- Bad, because ~16 `close()` sites in the most safety-critical file must be
  migrated and reviewed, and a subtle unawaited-future mistake there could leak
  a client past a disconnect (the exact class of bug the generation pinning
  exists to prevent).
- Neutral, because `SSHIdentity`/Secure Enclave is valuable but deferred — it
  needs its own integration decision, not a side effect of this upgrade.

## Pros and Cons of the Options

### Option 1: Adopt 3.x now, pin 3.3.0
* Good, because it delivers the peer-disconnect reason and hang-forever fixes
  exactly when we need them (during the MADR 0011 work).
* Good, because the security hardening (strict kex, AEAD ciphers, secure
  random) is real and immediate.
* Good, because migration cost is small and mechanical (~16 `close()` sites,
  one source-compatible `identities` site).
* Bad, because 3.x is young and the maintainer changed; churn risk requires
  pinning and review discipline.
* Bad, because the `close()` migration touches the generation-pinning
  safety-critical code and must be hand-reviewed.

### Option 2: Stay on 2.22.5
* Good, because zero migration risk and a known, stable pin.
* Bad, because we keep diagnosing disconnects blind — no peer reason string,
  and the hang-forever fixes stay out of reach.
* Bad, because we forgo strict-kex/AEAD/secure-random hardening that is
  directly relevant to a credential-moving client.
* Neutral, because 2.22.5 remains a supported, correct choice if the churn
  concern is judged decisive.

### Option 3: Adopt 3.x later (deferred)
* Good, because it lets 3.x accumulate field exposure before we depend on it.
* Good, because it decouples the upgrade from the MADR 0011 fix.
* Bad, because it defers the disconnect-reason diagnostic to a second pass,
  leaving the active bug investigation without its best signal.
* Bad, because it doubles the review effort (migrate once, then re-review the
  telemetry wiring later).

### Option 4: Fork/vendor 2.22.5
* Good, because full control over the transport.
* Bad, because it makes us the maintainer of a security-critical SSH
  implementation with no upstream — the worst possible outcome given the
  active, competent upstream that now exists.
* Bad, because it forfeits every 3.x fix and every future upstream fix.

## Confirmation

The decision is accepted when all of the following hold:

1. **Migration compiles clean**: `flutter analyze` passes with the repo's
   strict lints after migrating every `SSHClient.close()` call site and the
   `identities` site.
2. **Live transport green**: `flutter test test/ssh_live_transport_test.dart`
   (real loopback sshd) passes against 3.3.0 — connect, execute, compressed
   read, timeout-kill, in-flight-disconnect supersession, executor-seam parity.
3. **Full suite green**: `flutter test` clean, including the
   `ssh_transport_hardening_test.dart` transport tests.
4. **Disconnect reason wired**: `SSHDisconnectError` is caught in the
   `SSHClientManager`/`ConnectionController` drop path and its reason string
   recorded into `CommandTelemetry`'s `TransportDropSample` (extending the
   MADR 0011 telemetry), with a unit test asserting the reason propagates.
5. **Rekey behavior re-verified**: the 3.3.0 `_rekeyPendingPackets` behavior
   is checked against MADR 0011's finding; the upstream issue is filed or
   confirmed still open.

## More Information

- `github.com/vicajilau/dartssh2` — 260 stars, 107 forks, 581 commits,
  `SECURITY.md`, GitHub Actions CI, `codecov.yml`, 0 open issues/PRs at
  assessment time; pub.dev verified publisher `victorcarreras.dev`, 71.6k
  downloads, MIT.
- Contributor history (TerminalStudio repo): `vicajilau` 207, `xtyxtyx` 162,
  `GreenAppers` 51, `GT-610` 8 — the fork is the existing primary maintainer
  relocating, and `GT-610` is upstreaming from ServerBox's fork.
- dartssh2 3.x changelog: 3.0.0 (2026-08-16) `SSHIdentity` + `close()`→
  `Future<void>`; 3.0.1 secure random; 3.0.2 SFTP read data-loss fix; 3.1.0
  strict kex + EXT_INFO + AES-GCM default + hang-forever fixes (#207/#210/
  #212/#213); 3.2.0 ChaCha20-Poly1305 + hostbased + `SSH_MSG_UNIMPLEMENTED` +
  SFTP packet cap; 3.3.0 `SSHDisconnectError` + `SSHPacketError` + OpenSSH
  interop tests.
- Our migration surface: ~16 `SSHClient.close()` sites in
  `lib/core/ssh/ssh_client_manager.dart` (lines 288–630) and
  `lib/core/ssh/ssh_command_executor.dart`; one `identities:` site
  (`ssh_client_manager.dart:546-547`).
- Related: `0011-MADR-ssh-transport-stability-hardening.md` (drop-cause
  telemetry that `SSHDisconnectError` feeds) and
  `0011-PLAN-ssh-transport-stability-hardening.md`.
