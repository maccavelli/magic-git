---
status: "accepted"
date: 2026-08-19
decision-makers: [Maintainer]
consulted: []
informed: [Magic Git contributors]
verified: 2026-08-20
---

# Prefer dartssh2 3.3.0 over the dartssh3 package

## Context and Problem Statement

Magic Git's remote backend is an SSH transport: `SSHClientManager` and
`SSHCommandExecutor` drive `git` / `glab` / `gh` on a POSIX host through
`package:dartssh2`. The pin is `dartssh2: ^2.22.5`, locked at **2.22.5**
(`pubspec.yaml:39`, `pubspec.lock` `version: "2.22.5"`).

Two similarly named artefacts now exist on pub.dev, and both look like "the
3.x upgrade":

1. **`dartssh3` 3.0.3** (`pub.dev/packages/dartssh3`, repo
   `github.com/obemu/dartssh3`) — a third-party fork that advertises itself as
   the continuation of dartssh2 "because the original author stopped
   development." Last published **2025-06-24**.
2. **`dartssh2` 3.3.0** (`pub.dev/packages/dartssh2`, repo
   `github.com/vicajilau/dartssh2`, verified publisher `victorcarreras.dev`) —
   the same package we already depend on, now at major 3. Published
   **2026-08-18**. [0012-MADR-adopt-dartssh2-v3.md](./0012-MADR-adopt-dartssh2-v3.md)
   already proposed adopting this line.

The question this record answers is **technical feasibility**: is switching to
the `dartssh3` *package* a viable upgrade, and if not, is staying on the
`dartssh2` package and moving to its 3.x line feasible for *this* codebase,
given official docs, published best practices, and the APIs we actually call.

This record does not re-decide MADR 0011 (transport stability / busy-pause).
It does not replace MADR 0012: 0012 is the adopt-now decision for dartssh2
3.3.0. This record is the feasibility grounding, including the naming
collision 0012 did not treat as its problem statement.

## Decision Drivers

* **Compile-time compatibility** with the APIs we already call
  (`waitForExit`, `authTimeout`, SHA-256 `onVerifyHostKey` fingerprints,
  `SSHKeyPair.fromPem` into `identities`).
* **Security posture** of the negotiated defaults (AEAD ciphers, Terrapin
  strict-kex, `Random.secure()`, host-key verification).
* **Maintenance health**: verified publisher, pub points, analyzer cleanliness,
  recent commits, and whether the fork is a continuation or a stale snapshot.
* **Migration cost** against the safety-critical generation-pinning code in
  `lib/core/ssh/ssh_client_manager.dart`.
* **Fit to our architecture**: dual `SSHClient`, exec-channel (not SFTP)
  upload, application-level gzip (dartssh2 has no transport compression),
  reply-checked health monitor rather than the library's fire-and-forget
  keepalive.
* **Diagnosability** of the in-flight disconnect bug (MADR 0011): we need the
  peer's `SSH_MSG_DISCONNECT` reason to reach the caller.
* **Optimizations we can actually use**, not APIs that look modern on a README
  but do not map onto our executor seam.

## Considered Options

* Switch the dependency to the `dartssh3` package (3.0.3)
* Stay on `dartssh2` 2.22.5
* Upgrade `dartssh2` to 3.3.0 (same package, new major)
* Defer any 3.x move until dartssh2 3.x has more field exposure

## Decision Outcome

Chosen option: **"Upgrade dartssh2 to 3.3.0 (same package, new major)"**,
because switching to the `dartssh3` package is **not technically feasible**
for this codebase (it is a year-stale snapshot of dartssh2 ~2.13 that lacks
APIs we already compile against and would be a security and maintenance
downgrade), while dartssh2 3.3.0 is a small, documented, source-mostly-
compatible major on the library we already run, and it is the only artefact
that delivers `SSHDisconnectError`, hang-forever fixes, and the AEAD /
strict-kex defaults the official 3.x docs now recommend.

Feasibility of dartssh2 3.3.0 is **yes**, with a bounded, mechanical
migration (16 `SSHClient.close()` sites become `Future<void>`). Execution
is [0013-PLAN-prefer-dartssh2-v3-over-dartssh3.md](./0013-PLAN-prefer-dartssh2-v3-over-dartssh3.md),
which absorbs 0012-PLAN rather than running beside it.

### Naming collision (fact)

`dartssh3` is **not** dartssh2 3.x under a new name. Evidence:

| | `dartssh3` 3.0.3 | `dartssh2` 3.3.0 |
|---|---|---|
| pub.dev | [pub.dev/packages/dartssh3](https://pub.dev/packages/dartssh3) | [pub.dev/packages/dartssh2](https://pub.dev/packages/dartssh2) |
| Import | `package:dartssh3/dartssh3.dart` | `package:dartssh2/dartssh2.dart` (what we already import) |
| Publisher | unverified (`obemu`) | verified `victorcarreras.dev` |
| Last publish | 2025-06-24 (14 months before this record) | 2026-08-18 |
| Lineage | fork of dartssh2; changelog 3.0.3 is "rebased with commit `df127d7` from TerminalStudio/dartssh2"; 3.0.2 rebased to tag `2.12.0` | same package we pin; credits say TerminalStudio maintained it through 3.0.1, then the repo moved to `vicajilau/dartssh2` |
| Pub score (2026-08-19) | **60 / 160**, 0 likes, **67** downloads, incomplete analysis | **160 / 160**, 146 likes, **72.9k** downloads |
| Platform / analyzer | 0/20 platforms; 0/50 analysis — `sftp_client.dart:602` type error (`int?` vs `num`); `pointycastle ^3` while latest is 4.0.0; lower-bound downgrade reports 12 errors including missing `AESEngine` | 5/6 platforms (not web — irrelevant; we are macOS-only); 50/50 analysis; `pointycastle ^4.0.0` |
| Changelog hygiene | published changelog still contains unresolved git conflict markers (`<<<<<<< HEAD` / `>>>>>>> 4068b63`) | coherent 3.0.0–3.3.0 entries with PR links and OpenSSH interop tests |

The `dartssh3` README's claim that "the original author stopped development"
was already stale when 3.0.3 shipped (dartssh2 2.13.0 landed the same week)
and is false as of this writing: dartssh2 published six 3.x releases in
2026-08-16..18.

### Why `dartssh3` does not compile against our tree (fact)

Direct imports of `package:dartssh2/dartssh2.dart` live in four files:
`lib/core/ssh/ssh_client_manager.dart`,
`lib/core/ssh/ssh_command_executor.dart`,
`lib/core/ssh/ssh_error_messages.dart`,
`test/ssh_command_executor_test.dart`. Renaming the import is the easy part.
The APIs those files call are not on the dartssh3 3.0.3 surface
([SSHClient](https://pub.dev/documentation/dartssh3/latest/dartssh3/SSHClient-class.html),
[SSHSession](https://pub.dev/documentation/dartssh3/latest/dartssh3/SSHSession-class.html)
as of 2026-08-19):

| Our call site | What we need | dartssh3 3.0.3 | dartssh2 3.3.0 |
|---|---|---|---|
| `SSHSession.waitForExit()` — `ssh_command_executor.dart:153`, `:720` (added dartssh2 2.21.0) | present | **absent** (`exitCode` getter only) | present |
| `SSHClient(..., authTimeout:)` — `ssh_client_manager.dart:256`, `:268`, `:438`, `:583` (added 2.22.0) | named ctor arg | **absent** | present |
| `handshakeTimeout` (official 3.x docs; we do not pass it today) | optional | **absent** | present |
| `onVerifyHostKey` fingerprint | OpenSSH `SHA256:<base64>` (`ssh_client_manager.dart:226-228`; dartssh2 2.18.0 breaking) | pre-2.18 surface (raw MD5 digest in that era) | SHA-256, matches `ssh-keygen -lf` |
| `identities:` | `SSHKeyPair.fromPem(...)` (`ssh_client_manager.dart:546-548`) | `List<SSHKeyPair>?` | `List<SSHIdentity>?`; `SSHKeyPair` still implements `SSHIdentity` — constructor remains source-compatible |
| `SSHClient.close()` | we fire-and-forget at 16 sites | `void` | **`Future<void>`** (3.0.0 breaking) |
| `SSHDisconnectError` | needed for MADR 0011 drop-cause | **absent** | present (3.3.0) |
| `strictKex` / AES-GCM / ChaCha20 defaults | security | AES-CTR/CBC + hmac-md5/sha1/sha2 only; no AEAD, no Terrapin countermeasure | AES-GCM → ChaCha20-Poly1305 → CTR; strict-kex negotiated automatically |
| KEX offloaded to `Isolate.run` | UI freeze during connect | not present (pre-2.20) | present since 2.20.0 (already in our 2.22.5 pin) |

A dartssh3 swap is therefore a **compile-breaking downgrade** of at least
four months of dartssh2 API (2.16–2.22) plus the entire 3.x hardening line.
It also regresses the host-key fingerprint format our TOFU store and
`serializeHostKeyVerifier` are written against.

### Why dartssh2 3.3.0 *is* feasible (fact)

**Breaking surface we actually touch** (verified against the 3.3.0 API docs
and [0012-PLAN](./0012-PLAN-adopt-dartssh2-v3.md)'s pub-cache review):

1. `SSHClient.close(): void → Future<void>`. All 16 call sites are in
   `ssh_client_manager.dart` (lines 288, 303, 313, 314, 324, 328, 350, 353,
   390, 454, 573, 587, 595, 607, 628, 630).
   `ssh_command_executor.dart` has **zero** `SSHClient.close()` sites —
   `session.close()` is `SSHSession.close()`, still `void`.
   Wrapping each site in `unawaited(...)` preserves today's fire-and-forget
   teardown and satisfies `unawaited_futures`. No generation-pinning order
   change is required.
2. `SSHClient.identities` getter type `List<SSHKeyPair>? → List<SSHIdentity>?`.
   The constructor site at `ssh_client_manager.dart:546-548` stays
   source-compatible (`SSHKeyPair implements SSHIdentity`).

**SDK:** dartssh2 3.x requires Dart ≥ 3.0; we already require `sdk: ^3.12.2`.

**What does not change:** `SSHSession.close()`, `SftpClient.close()` (already
`Future<void>` since 2.22.3; we do not call SFTP), `SSHSocket.connect`,
`SSHClient.execute` / `ping` / `authenticated` / `done`, `keepAliveInterval: null`,
`onVerifyHostKey`, `SSHAuthFailError` / `SSHAuthAbortError` / `SSHHostkeyError`
/ `SSHKeyDecodeError` consumed by `humanizeSshError`.

**What 3.x adds that we want, mapped to our code:**

* `SSHDisconnectError` (3.3.0) — peer reason code + description. Today
  `humanizeSshError` has no branch for it (`ssh_error_messages.dart`); a
  clean `SSH_MSG_DISCONNECT` falls through to `toString()`. MADR 0011's drop
  path already listens to `SSHClient.done` completing with an error; 3.3.0
  is what makes that error *attributable*.
* Hang-forever fixes (3.1.0 #212 / #210) — global-request / channel-open
  whose reply can never arrive now fails with the connection error; receive
  window is replenished after a slow reader. Directly relevant to
  `ConnectionHealthMonitor.ping` (`ssh_client_manager.dart:59-60`, `:99`)
  and to `executeStream` consumers (watcher, CI trace).
* Strict key exchange (`kex-strict-c-v00@openssh.com`, Terrapin
  CVE-2023-48795) + AES-GCM / ChaCha20-Poly1305 defaults (3.1.0 / 3.2.0) —
  automatic; no call-site change. `SSHClient.strictKex` is readable after
  auth if we want to log it.
* `Random.secure()` for all protocol randomness (3.0.1) — automatic.
* `SSHPacketError` instead of `RangeError`/`IndexError` on malformed packets
  (3.3.0) — our `SSHError` handlers will start seeing these; they should be
  added to `humanizeSshError` as part of the 0012 migration, not left as raw
  `toString()`.
* OpenSSH interop tests (3.3.0) — first time the library tests itself
  against a real sshd rather than only itself. Complements our
  `test/ssh_live_transport_test.dart`.

**What 3.x does *not* fix (assumption confirmed by 0012-PLAN against 3.3.0
source, to be re-checked at migration time):**
`_rekeyPendingPackets` remains an unbounded buffer; `SSH_MSG_GLOBAL_REQUEST`
(ping) is still queued during rekey. MADR 0011's busy-pause remains
necessary. The upgrade is not a substitute for 0011.

### Official docs — best practices vs what we already do

Source: dartssh2 3.3.0 README and
[SSHClient API](https://pub.dev/documentation/dartssh2/latest/dartssh2/SSHClient-class.html),
retrieved 2026-08-19.

| Official recommendation | Our current code | Action on 3.3.0 |
|---|---|---|
| Always pass `onVerifyHostKey`; omitting it **accepts every host key** | Implemented. TOFU via `KnownHostsStore`; dual-handshake verifier is serialized (`ssh_client_manager.dart:225-251`, `:466-493`). Fingerprint documented as `SHA256:<base64>`. | Keep. Do not regress. |
| Never set `disableHostkeyVerification: true` outside local tests | We never pass it. | Keep never passing it. |
| Set `handshakeTimeout` and `authTimeout` so KEX/auth cannot hang forever | Socket connect timeout 15 s (`:123`, `:505-508`). Auth is a *pausable* 15 s wrapper around `client.authenticated` so a host-key prompt does not trip the timer (`:511-515`, `:581-585`). Library `handshakeTimeout` is **not** passed. | Optional: pass `handshakeTimeout: _socketTimeout` as defense in depth. Do **not** replace the pausable auth wrapper with the library `authTimeout` — the library timeout cannot distinguish "stuck" from "waiting on a person." |
| `await client.close()` so socket + channels finish tearing down | 16 fire-and-forget `close()` sites. | `unawaited(client.close())` at every site (preserves order; satisfies the new `Future` return). Await only if a future change needs teardown-before-redial sequencing — none does today. |
| Use `session.stdin.addStream` for large payloads; `session.write` is `stdin.add` | `uploadBytes` feeds the whole `Uint8List` through `s.write(stdin)` then `s.stdin.close()` (`ssh_command_executor.dart:324-333`, `:666-674`). Sideloads can be large (timeout is sized at 64 KiB/s). | Independent optimization, valid on 2.22.5 *and* 3.3.0: stream the bytes. Not a 3.x blocker. |
| Offload `SSHKeyPair.fromPem` (bcrypt KDF) with `compute` | `fromPem` runs on the UI isolate as a constructor argument (`ssh_client_manager.dart:516-518`, `:546-548`). | Independent optimization. Encrypted-key connect can freeze the UI today. Out of scope for the version bump. |
| `client.run()` for simple commands; `execute()` when you need streams / stdin / kill | We correctly use `execute()` + bounded drain + `waitForExit` + TERM→KILL. `run()` would drop our byte budget, gzip trailer, generation pin, and lane scheduler. | Do **not** switch to `run()` / `runWithResult()`. |
| Leave algorithm defaults alone; only pass `SSHAlgorithms` to revive broken suites | We pass none. 3.1.0 defaults become AES-GCM-first automatically. | Do not pin legacy CTR/CBC. Do not re-enable `dh-group1-sha1` / `hmac-md5` / truncated hmac. |
| Library `keepAliveInterval` (default 10 s) | Explicitly `null` (`:549-554`). `ConnectionHealthMonitor` reply-checks `ping()` with a 15 s timeout and a 3-failure threshold. MADR 0011 documents why the library keepalive is fire-and-forget. | Keep `null`. Re-enabling it would double global-request traffic on the command client during bulk reads. |
| SFTP `download` pipelining / `chunkSize` / `maxPendingRequests` | We do **not** use SFTP. Sideload is `cat > path` on an exec channel because `SftpClient.close()` historically leaked a `MaxSessions` slot (`ssh_command_executor.dart:324-333`). | Do not adopt SFTP as a side effect of this upgrade. Revisit only with its own decision. |
| `SSHIdentity` / Secure Enclave / `shouldProbe` | PEM in memory (and Keychain). ARCHITECTURE_PLAN §0.1: "No ssh-agent client auth in dartssh2; `agentHandler` is agent *forwarding* only." | Deferred. Valuable later; not required to land 3.3.0. |

### Optimizations in scope vs out of scope

**In scope for the 3.3.0 bump** (cheap, follow from the new API):

1. Mechanical `unawaited(close())` migration.
2. Catch `SSHDisconnectError` on `client.done` and record
   `reasonCode` + `message` into MADR 0011's drop telemetry; add a
   `humanizeSshError` branch.
3. Catch `SSHPacketError` in `humanizeSshError` so malformed-packet drops
   are not presented as a raw Dart `RangeError`.
4. Optionally pass `handshakeTimeout` equal to the existing 15 s socket
   timeout.
5. Optionally log `client.strictKex` and `client.remoteVersion` after
   `authenticated` (connect diagnostics; no behavior change).

**Out of scope** (real optimizations, separate decisions):

* `stdin.addStream` for sideloads.
* `compute(...)` around `SSHKeyPair.fromPem`.
* `SSHIdentity` + Secure Enclave / hardware keys.
* Switching uploads to SFTP now that 3.2.0 caps SFTP packets at 256 KiB.
* Re-enabling library keepalive or asking for `SocketOption.tcpKeepAlive`.
* Replacing application gzip with a transport-compression feature the
  library still does not have (`ARCHITECTURE_PLAN.md` §0.1).

### Churn and pin

3.0.0 → 3.3.0 shipped in ~48 hours. That is a focused hardening sprint
(changelog entries are test-backed and coherent), not six unrelated
breakages, but it means 3.x has days — not weeks — of field exposure.
**Pin the exact version `3.3.0`**, not `^3.3.0`, until a later 3.x has sat
in our live-sshd suite. This matches 0012.

## Consequences

* Good, because the `dartssh3` naming trap is recorded: a future search for
  "upgrade to dartssh3" will land here and be told not to change the package
  name.
* Good, because dartssh2 3.3.0 is a feasible, mechanical migration that
  unlocks peer-disconnect reasons, hang-forever fixes, and AEAD / strict-kex
  defaults with no architecture change.
* Good, because official 3.x best practices mostly confirm what we already
  do (`onVerifyHostKey`, `execute` not `run`, keepalive owned by
  `ConnectionHealthMonitor`, no SFTP, no `disableHostkeyVerification`).
* Bad, because 3.3.0 is two days old at the time of writing; the pin and the
  live-sshd suite bound that risk, they do not eliminate it.
* Bad, because the `close()` `Future` migration touches every teardown path
  in the generation-pinning file; a missed `unawaited` is an analyzer error,
  but a wrongly *awaited* close could reorder disconnect vs. attach.
* Neutral, because MADR 0011's rekey-buffer finding is unchanged by 3.3.0;
  busy-pause stays the remediation.
* Neutral, because `SSHIdentity` / Secure Enclave and the stdin-stream /
  PEM-`compute` optimizations are real and still deferred.

### Confirmation

This decision holds when all of the following are true:

1. No `dartssh3:` entry exists in `pubspec.yaml`. The import remains
   `package:dartssh2/dartssh2.dart`.
2. After the 3.3.0 bump, `flutter analyze` is clean with the repo's strict
   lints (the `unawaited_futures` lint is the close-site gate).
3. `flutter test test/ssh_live_transport_test.dart` and `flutter test` are
   green against 3.3.0.
4. A peer `SSH_MSG_DISCONNECT` surfaces as `SSHDisconnectError` on
   `SSHClient.done` and is recorded / humanized (0012 Phase 2).
5. 3.3.0 source is re-checked for `_rekeyPendingPackets`; if still
   unbounded, the 0011 busy-pause plan is not dropped.

## Pros and Cons of the Options

### Switch the dependency to the `dartssh3` package (3.0.3)

A different package (`obemu/dartssh3`), last published 2025-06-24, forked
when dartssh2 development was assumed dead.

* Good, because the import rename looks small on a first reading of the
  README (same `SSHClient` / `SSHSocket` / `execute` shape).
* Bad, because it does not compile against this tree: `waitForExit` and
  `authTimeout` are missing, and the host-key fingerprint format predates
  the SHA-256 change our TOFU store depends on.
* Bad, because it is a security downgrade: no AES-GCM, no ChaCha20-Poly1305,
  no strict-kex, no `Random.secure()` sweep, no `SSHDisconnectError`.
* Bad, because pub analysis currently fails (0/50 analyzer, 0/20 platforms,
  stale `pointycastle ^3`), the publisher is unverified, and the published
  changelog contains merge-conflict markers.
* Bad, because 67 downloads vs dartssh2's 72.9k is not a healthy
  alternative — it is an abandoned snapshot.

### Stay on `dartssh2` 2.22.5

* Good, because zero migration risk and a known pin.
* Bad, because disconnects stay unattributable (no `SSHDisconnectError`) and
  the 3.1.0 hang-forever / window-stall fixes stay out of reach — both are
  load-bearing for the MADR 0011 investigation.
* Bad, because we forgo AEAD-default and Terrapin strict-kex on a client
  that moves credentials and pack data over untrusted links.
* Neutral, because 2.22.5 is a correct, currently-working choice if the 3.x
  age is judged decisive.

### Upgrade `dartssh2` to 3.3.0 (same package, new major)

* Good, because the only breaking change we touch is `close(): Future<void>`,
  concentrated in one file, mechanically wrapped with `unawaited`.
* Good, because official 3.x docs and our architecture already agree on the
  important practices; we inherit security and hang fixes for free.
* Good, because `SSHDisconnectError` feeds the drop-cause telemetry 0011
  is adding.
* Bad, because 3.x is days old; an exact pin and the live-sshd suite are
  required, not optional.
* Neutral, because the rekey-buffer stall is not fixed and must not be
  assumed fixed.

### Defer any 3.x move until dartssh2 3.x has more field exposure

* Good, because it lets 3.x accumulate weeks of production use (ServerBox,
  NoPorts, NaviTerm, TealKit are listed consumers).
* Bad, because it defers the one diagnostic (`SSHDisconnectError`) the
  active disconnect investigation is missing, and it doubles review
  (migrate later, then re-review telemetry wiring).
* Neutral, because the exact pin already bounds churn; waiting is a
  schedule choice, not a feasibility one. Feasibility is already yes.

## More Information

### Codebase facts (this repo, 2026-08-19)

* Pin: `pubspec.yaml:39` `dartssh2: ^2.22.5`; `pubspec.lock` locks `2.22.5`.
* Transport ownership: `lib/core/ssh/ssh_client_manager.dart` (dual client,
  generation pinning, serialized host-key verify, reply-checked health
  monitor, `keepAliveInterval: null`).
* Exec seam: `lib/core/ssh/ssh_command_executor.dart` (`execute` + bounded
  drain + `waitForExit`; exec-channel upload, not SFTP; application gzip).
* Error copy: `lib/core/ssh/ssh_error_messages.dart` (no
  `SSHDisconnectError` / `SSHPacketError` branches yet).
* Authoritative transport notes: `docs/ARCHITECTURE_PLAN.md` §0.1.
* Related decisions: `0011-MADR-ssh-transport-stability-hardening.md`
  (busy-pause + drop-cause telemetry), `0012-MADR-adopt-dartssh2-v3.md`
  (adopt 3.3.0 now), `0012-PLAN-adopt-dartssh2-v3.md` (execution).

### External evidence (retrieved 2026-08-19)

* dartssh2 3.3.0 README, changelog, score (160/160), and
  [SSHClient API](https://pub.dev/documentation/dartssh2/latest/dartssh2/SSHClient-class.html).
* dartssh3 3.0.3 README, changelog (incl. conflict markers), score (60/160),
  [SSHClient API](https://pub.dev/documentation/dartssh3/latest/dartssh3/SSHClient-class.html),
  [SSHSession API](https://pub.dev/documentation/dartssh3/latest/dartssh3/SSHSession-class.html),
  GitHub `obemu/dartssh3` (fork of `vicajilau/dartssh2`).
* Terrapin / CVE-2023-48795 countermeasure as documented by dartssh2 3.1.0
  (`kex-strict-c-v00@openssh.com`).

### Assumptions (not independently re-verified in this pass)

* 0012-PLAN's pub-cache line numbers for `_rekeyPendingPackets` in 3.3.0
  source. Re-confirm at migration time (0012 Phase 3).
* No other file beyond the four listed imports dartssh2 symbols. A
  repo-wide search of `*.dart` found only those four `package:dartssh2`
  imports plus documentation comments.

Implementation plan:
[0013-PLAN-prefer-dartssh2-v3-over-dartssh3.md](./0013-PLAN-prefer-dartssh2-v3-over-dartssh3.md).
That plan is the execution vehicle: it absorbs 0012's mechanical bump and
adds this record's extra gates (no `dartssh3` package, `SSHPacketError`
copy, `handshakeTimeout`, drop-reason surfacing that does not wait on
MADR 0011). Do not execute 0012-PLAN in parallel.
