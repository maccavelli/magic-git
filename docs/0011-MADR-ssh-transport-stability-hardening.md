---
status: "proposed"
date: 2026-08-18
decision-makers: [Maintainer]
consulted: []
informed: [Magic Git contributors]
---

# Harden the SSH transport against false-positive session kills during fetch/pull/push

## Context and Problem Statement

Users on SSH remotes report that `fetch`, `pull`, and `push` intermittently drop
the session: the connection dies mid-operation and the app auto-reconnects,
failing the in-flight command. Analysis of the transport stack
(`lib/core/ssh/ssh_client_manager.dart`, `lib/core/ssh/ssh_command_executor.dart`)
and the pinned library (`dartssh2 ^2.22.5`) identifies the likely killer: the
**activity-blind dead-peer monitor** falsely declaring a healthy-but-busy
connection dead, compounded by **dartssh2's rekey packet buffering** stalling
ping traffic mid-transfer. We need a root-cause fix that makes liveness probing
aware of in-flight activity, plus telemetry that proves the cause, and
operational guidance that keeps remotes from contributing.

### How a session currently dies during a network op

1. The command client multiplexes 4 concurrent compressed reads, a
   `sync`-lane fetch/push, and health pings over **one TCP connection**
   (dual-client only moves streams off it; reads + sync + pings share it).
2. `ConnectionHealthMonitor` (`ssh_client_manager.dart:48`) pings every 15 s
   with a 15 s reply timeout and declares the connection dead after 3
   consecutive failures — i.e. ~45–60 s of unanswered pings, regardless of
   whether the connection is streaming megabytes of pack data.
3. On a saturated or high-RTT link, ping replies (global requests that queue
   behind bulk channel data on the return path) are starved past 15 s. A
   big push or fetch routinely sustains this for over a minute.
4. Concurrently, OpenSSH servers rekey after `RekeyLimit` (default 1 GB or
   1 hour) — easily crossed mid-fetch/mid-push. During rekey, dartssh2
   buffers **every non-KEX outgoing packet** (verified in
   `ssh_transport.dart:260`: only message IDs 20–49 and ≤ 4 bypass;
   `SSH_MSG_GLOBAL_REQUEST` = 80 is queued) in an **unbounded**
   `_rekeyPendingPackets` list until `NEW_KEYS` arrives. Pings and their
   replies are delayed for the whole window.
5. Three timed-out pings → `onDead()` force-closes **both** clients
   (`ssh_client_manager.dart:347`) → `done` completes → `ConnectionController`
   enters `lost` and auto-reconnects. The in-flight fetch/pull/push fails with
   a transport error. The user sees exactly the reported symptom.

The monitor's failure threshold is deliberately conservative for *idle*
detection, but it has no notion of "the connection is busy carrying real
work" — and busy is precisely when its pings lose the arbitration.

## Decision Drivers

- A network op in flight must never be killed by the liveness monitor while
  data is actually flowing; the command's own outcome is the authoritative
  liveness signal during activity.
- Idle dead-peer detection (NAT/firewall silently dropping the session) must
  stay fast — that is the monitor's real job, and the current ~45–60 s
  detection is good.
- Works with stock OpenSSH servers and unmodified dartssh2; no protocol-level
  or server-side changes required to fix the client.
- Root-cause fix only, consistent with the repo's working style — no symptom
  guards, no retry-as-bandaid around the monitor.
- Must produce verifiable evidence: telemetry that distinguishes
  monitor-declared-death from genuine transport error.
- Existing pinned behavior in `test/ssh_transport_hardening_test.dart`
  (parallel handshakes, redial backoff, etc.) must keep passing; new behavior
  gets its own tests plus live-sshd coverage in
  `test/ssh_live_transport_test.dart`.

## Considered Options

1. **Activity-aware health monitoring with busy-pause** — make the monitor
   skip/fuzz probing while network-bound work is in flight, reset failures on
   any command completion or byte activity, and record the death cause in
   `CommandTelemetry`.
2. **Static widening** — raise ping timeout/threshold globally (e.g. 30 s / 5).
   Simple, but slows idle detection for everyone and still fails on very slow
   saturated links; treats the symptom, not the cause.
3. **RTT-adaptive probe budget** — derive ping timeout from measured RTT
   samples (e.g. `max(15 s, 8 × RTT)`), scaling the failure window to the
   link. Elegant, but pings still compete with bulk data and it does nothing
   about the rekey buffering stall; high complexity for partial coverage.
4. **Library-side keepalive + TCP keepalive** — re-enable dartssh2's
   `keepAliveInterval` and request `SocketOption.tcpKeepAlive` exposure
   upstream. Complementary at best: the library keepalive is fire-and-forget
   (no reply check, the reason it was disabled) and doubles global-request
   traffic; macOS TCP keepalive idle defaults (~2 h) are useless against
   NAT drops measured in minutes.
5. **Do nothing — rely on auto-reconnect** — the drop storm fails every
   in-flight command, forces a full connect+auth cycle, and on hosts with
   tight `MaxAuthTries`/fail2ban policies risks locking the user out. Not a
   remediation.

## Decision Outcome

Chosen option: **"Activity-aware health monitoring with busy-pause"**, because
it removes the false-positive kill at its root (probing a connection that is
demonstrably busy), keeps idle dead-peer detection exactly as fast as today,
needs no dartssh2 or server changes, and ships with drop-cause telemetry that
proves the fix in production.

### Design (summary)

**Busy signal.** `SSHCommandExecutor` gains a transport-busy accounting
(an increment/decrement of in-flight commands per lane, plus a
"bytes received recently" latch fed by the output-drain paths). Exposed to
`SSHClientManager`; both the command-client and stream-client monitors consume
it.

**Probe policy while busy.**
- A ping already in flight when the connection turns busy completes normally
  (its timeout still applies — it is a liveness probe, not a kill decision).
- While busy, the monitor **skips** new probes. Death while busy is detected
  by the work itself: the command's own `timeout` (3 min network timeout for
  fetch/pull/push, 60 s default reads, `SSHCommandTimeout`/transport errors)
  and the existing `_watchForDrop` listener on `client.done` (which already
  catches error-completed drops) — a genuinely dead link surfaces within the
  command's budget either way, and the drop path triggers auto-reconnect
  unchanged.
- **Failure reset on activity**: any command settling (success or failure —
  the channel closed, so the connection was alive) and any observed stream
  bytes reset the consecutive-failure counter to zero. Stale failures from a
  pre-transfer blip can never accumulate across a busy period into a kill.
- Idle policy is unchanged: 15 s interval, 15 s timeout, 3 failures
  (~45–60 s detection).

**Rekey-window tolerance falls out for free**: a server-initiated rekey
(1 GB / 1 h `RekeyLimit`) only happens *during* bulk transfer, when the busy
policy has already suspended probing — the buffered-packet stall can no longer
count toward a kill.

**Drop-cause telemetry.** `ConnectionHealthMonitor` records a
`TransportDrop` sample (cause: `monitor`, `transport`, `local-close`; failure
count at death; busy/active at death; age; last command label) into
`CommandTelemetry`, surfaced on the connection dashboard. This is the
Confirmation evidence and the tripwire for any future regression.

**Operational guidance** (docs, not code): recommend remotes keep
`ClientAliveInterval` ≤ 60 s with `ClientAliveCountMax` ≥ 3, leave
`RekeyLimit` at default or higher, and avoid aggressive `MaxSessions` limits;
note NAT/LB idle-timeout behavior (AWS NLB 350 s etc.) as context for why the
client probes at 15 s. File upstream issues for dartssh2: bound
`_rekeyPendingPackets` (a stalled rekey buffers forever, per PR #125's own
author) and expose `SocketOption.tcpKeepAlive`.

**Deferred refinements**: the RTT-adaptive probe budget (Option 3) can be
layered on later if telemetry shows slow-idle-detection complaints; automatic
re-issue of superseded reads after reconnect is already covered by the UI's
refresh-on-reconnect and stays out of scope.

* Implementation Plan:
  [0011-PLAN-ssh-transport-stability-hardening.md](./0011-PLAN-ssh-transport-stability-hardening.md)
  (companion plan to be written once this decision is accepted).

## Consequences

- Good, because the monitor can no longer kill a connection that is carrying
  real work; fetch/pull/push failures become genuinely rare instead of
  self-inflicted.
- Good, because idle dead-peer detection latency is unchanged (~45–60 s) —
  the current, well-tuned behavior stays for the case the monitor exists for.
- Good, because drop-cause telemetry converts "it disconnected" into
  attributable data, and rekey-window tolerance costs nothing extra.
- Bad, because a connection that dies *while busy* is now detected via the
  command's own timeout (up to 3 min for network ops) instead of a fast ping
  kill — but killing it would have failed the command anyway, so the
  user-visible cost is identical while the false-positive cost disappears.
- Bad, because transport-busy accounting adds state to
  `SSHCommandExecutor` that must be kept balanced across success, failure,
  supersession, and stream cancellation paths (covered by tests).
- Neutral, because no dartssh2 upgrade, server config, or protocol change is
  required; the fix is entirely within the existing executor seam.

## Pros and Cons of the Options

### Option 1: Activity-aware health monitoring with busy-pause
* Good, because it fixes the root cause: pings only probe when the connection
  is idle, which is the only state where unanswered pings mean death.
* Good, because command-outcome and byte-activity failure resets make the
  counter robust against transient blips and rekey windows.
* Good, because drop-cause telemetry provides hard confirmation evidence.
* Bad, because busy-state accounting adds a small bookkeeping surface that
  must be tested across every settle path.
* Neutral, because idle detection behavior is unchanged by design.

### Option 2: Static widening (e.g. 30 s timeout / 5 failures)
* Good, because it is a one-line change and reduces (not removes) false kills.
* Bad, because it slows idle dead-peer detection to ~2.5 min for every
  connection, on every link, forever.
* Bad, because a saturated 1 Mbps link can still starve pings past 30 s —
  it does not fix the cause, only the calibration.
* Neutral, because it needs no new state.

### Option 3: RTT-adaptive probe budget
* Good, because the failure window scales with measured link latency, and it
  reuses the existing RTT-sample pipeline (`onPingSample` →
  `AdaptiveReadConcurrency`).
* Bad, because pings still compete with bulk data on the same TCP connection;
  a link saturated in the *return* direction delays replies beyond any
  RTT-derived budget.
* Bad, because it does nothing for the rekey buffering stall, and adds
  feedback-loop complexity (probe budget derived from probe replies) that is
  hard to test deterministically.
* Neutral, because it can later be layered on Option 1 if telemetry warrants.

### Option 4: Library keepalive + TCP keepalive
* Good, because it adds an independent liveness signal with no app state.
* Bad, because dartssh2's `keepAliveInterval` is fire-and-forget — no reply
  check — which is exactly the flaw that led to `ConnectionHealthMonitor`;
  re-enabling it doubles global-request traffic during bulk reads.
* Bad, because dartssh2 does not expose `SocketOption.tcpKeepAlive`
  (verified in the 2.22.5 source; `SSHSocket.connect` takes only `timeout`),
  and macOS's TCP keepalive idle default (~2 h) is useless against NAT drops
  measured in minutes.
* Neutral, because an upstream PR for the socket option remains worthwhile as
  belt-and-suspenders for idle flows.

### Option 5: Do nothing — rely on auto-reconnect
* Good, because nothing changes and the reconnect machinery already exists.
* Bad, because every drop fails every in-flight command, wastes a full
  connect+auth cycle (15 s socket + KEX + auth), and repeatedly cycling auth
  on tight `MaxAuthTries`/fail2ban hosts risks lockout.
* Bad, because it keeps the bug and the user-visible churn indefinitely.
* Neutral, because the telemetry for "was it the monitor?" would never be
  collected.

## Confirmation

Verification criteria — the fix is accepted when all of the following pass:

1. **Unit tests** (new cases in `test/ssh_transport_hardening_test.dart`):
   - Pings timing out while a sync-lane command is in flight → monitor must
     NOT declare the connection dead, and no new probes are sent while busy.
   - Any command settling (success or transport failure) resets the failure
     counter; a pre-busy blip followed by a long busy transfer never kills.
   - Idle dead-peer detection still fires at 3 consecutive failures within the
     expected window (unchanged behavior, existing tests updated to pin it).
   - Busy accounting is balanced across success / failure / `SSHCommandSuperseded` /
     stream cancel paths (no leaked busy count).
   - `TransportDrop` samples record the correct cause, failure count, and
     busy-at-death flag.
2. **Live integration** (`test/ssh_live_transport_test.dart`, `integration`
   tag, real disposable sshd on loopback): a large bulk transfer (synthetic
   multi-hundred-MB read / `git fetch` of a seeded repo) with deliberately
   slow ping replies completes with zero monitor kills; an idle connection
   killed by closing the server still auto-reconnects.
3. **Telemetry**: the dashboard surfaces drop-cause samples; a soak run
   (throttled link, e.g. Network Link Conditioner at 1 Mbps, repeated
   fetch/pull/push over 30+ minutes) reports zero `monitor`-cause drops and
   zero unexpected reconnects.
4. **Regression**: `flutter analyze` and `flutter test` clean, including all
   pre-existing transport hardening tests.

## More Information

- dartssh2 2.22.5 source, `lib/src/ssh_transport.dart:247-263` and
  `:1404-1409` — rekey buffering of all non-KEX packets, unbounded
  `_rekeyPendingPackets`; `lib/src/ssh_client.dart:689-693` — `ping()` is a
  `keepalive@openssh.com` global request awaiting the reply queue.
- dartssh2 PR #125 "Add support for server initiated re-keying" (released in
  2.13.0) — the buffering design and its unbounded-buffer caveat, noted by the
  PR author.
- dartssh2 changelog — keepalive overlap fix and error-catching during ping
  execution (relevant to `ConnectionHealthMonitor._probeInFlight`).
- `docs/ARCHITECTURE_PLAN.md` §0.1 — authoritative transport description and
  its "known gaps" list (streams don't migrate back after redial; channel-open
  telemetry not fed back into the read cap).
- OpenSSH keepalive guidance: client-side `ServerAliveInterval`/
  `ServerAliveCountMax` and server-side `ClientAliveInterval`/
  `ClientAliveCountMax` run inside the encrypted channel; NAT/LB idle
  timeouts (e.g. AWS NLB 350 s, corporate firewalls 60–300 s) dominate
  idle-drop behavior, which is why the client probes at 15 s.
- OpenSSH `RekeyLimit` (default 1 GB / 1 h) — the trigger for mid-transfer
  rekey windows on large fetch/push.
- **Dependency pin (2026-08-18)**: `dartssh2` bumped `^2.22.0` → `^2.22.5`
  (locked 2.22.5). Drop-in compatible; picks up the `SftpClient.close()`
  channel-leak fix (2.22.3) and the RFC 8731 `curve25519-sha256` name
  (2.22.4). The package has moved maintainers — from TerminalStudio to
  `github.com/vicajilau/dartssh2` (pub.dev verified publisher
  `victorcarreras.dev`) — and a 3.x line exists (latest 3.3.0) whose
  `SSHDisconnectError` (peer `SSH_MSG_DISCONNECT` reason surfacing) and
  hang-forever fixes (#212/#210) are directly relevant to this decision's
  drop-cause telemetry. The 3.x upgrade is **deferred to its own decision**:
  it is a breaking change (`SSHClient.close()` → `Future<void>`, `identities`
  type change) and the new maintainer warrants a separate review; the
  unbounded `_rekeyPendingPackets` buffer is not addressed in any 3.x
  changelog entry, so the upstream issue below still stands.
