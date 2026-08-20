---
status: proposed
date: 2026-08-19
decision-makers: [Maintainer]
consulted: []
informed: [Magic Git contributors]
---

# Treat the 2026-08 SSH engine assessment as the next-wave hardening backlog

## Context and Problem Statement

Magic Git's remote backend is an SSH engine: `SSHClientManager` +
`SSHCommandExecutor` drive `git` / `glab` / `gh` on a POSIX host through
`package:dartssh2` **3.3.0** (exact pin), with dual clients, generation
pinning, busy-pause liveness, lane scheduling, application gzip, and
auto-reconnect. MADRs [0011](./0011-MADR-ssh-transport-stability-hardening.md)
(busy-pause) and [0013](./0013-MADR-prefer-dartssh2-v3-over-dartssh3.md)
(dartssh2 3.3.0 over the stale `dartssh3` package) have shipped. The engine
is no longer a prototype; it is the load-bearing path for every remote
feature.

The remaining question is not "which SSH library" or "should the monitor
kill a busy fetch." It is: **given official dartssh2 3.3.0 docs, OpenSSH
`sshd_config(5)` (including 10.5, 2026-08-11), RFC 4253/4254, and the
current tree, which tunables and architectural moves actually improve
stability, robustness, and performance — and which look clever but fight
the protocol or our own invariants?**

This record is an assessment, in the same role as
[0004](./0004-MADR-ui-ux-deep-debug-audit.md): findings are evidence, the
decision is how to order them. It does **not** reopen 0011 or 0013. It does
not authorise implementation; a paired PLAN is required before any source
change.

### Audit method

* Read `lib/core/ssh/` and `lib/core/exec/` (manager, executor, lanes,
  adaptive cap, drain, telemetry, formatter, health monitor) plus the
  reconnect loop in `lib/core/providers/app_providers.dart`.
* Cross-check `docs/ARCHITECTURE_PLAN.md` §0.1 (authoritative transport
  notes, refreshed 2026-08-19) and the deferred items in 0011 / 0013.
* Read dartssh2 **3.3.0** source in the pub cache
  (`ssh_transport.dart`, `ssh_client.dart`, `ssh_channel.dart`,
  `ssh_socket_io.dart`) and the published
  [changelog](https://pub.dev/packages/dartssh2/changelog).
* Read OpenBSD `sshd_config(5)`, OpenSSH 10.5 release notes, and RFC 4254
  §5 (channel windows, `SSH_MSG_GLOBAL_REQUEST` = 80).

Tests and a live session were **not** re-run for this pass. Numbers below
are from source, not from a production drop ring.

### What is already true (do not re-solve)

* Dual `SSHClient` (commands vs long-lived streams), degrade-to-single,
  stream redial 15s→120s / 5 failures.
* Generation pinning at enqueue and at run; `SSHCommandSuperseded` is never
  retried.
* Busy-pause: skip new pings while `_activeCommands > 0` or a stream has
  received bytes in the last 30 s; reset failures on settle / stream bytes.
* Library `keepAliveInterval: null`. Reply-checked `SSHClient.ping` every
  15 s, 15 s timeout, 3 failures (~45–60 s idle death).
* `handshakeTimeout` = 15 s socket timeout; auth stays on the pausable
  wrapper so a host-key prompt does not trip it.
* Application `gzip -c -1` (dartssh2 still advertises compression `none`).
* Read cap 4, isolated cap 2, watchdog = command timeout + 30 s.
* Exact pin `dartssh2: 3.3.0`. AES-GCM-first, strict-kex, `SSHDisconnectError`,
  hang-forever fixes on unanswered channel/global requests, and the
  3.1.0 receive-window replenish after a slow reader (PR #210) are already
  in the binary we run.

## Decision Drivers

* **A busy connection must not be declared dead by the liveness monitor.**
  0011 already owns this; next-wave work must not re-enable competing
  keepalives or shrink the busy window without evidence.
* **Idle NAT/firewall drops must stay detectable in ~45–60 s.** Widening
  every timeout "just in case" is how idle sessions go stale for minutes.
* **Stock OpenSSH remotes.** Default `MaxSessions 10`, `MaxAuthTries 6`,
  `LoginGraceTime 120`, `RekeyLimit` 1–4 GiB / no time limit,
  `ClientAliveInterval 0`, `TCPKeepAlive yes`, `PerSourcePenalties` on
  (OpenSSH ≥ 9.8). We do not require custom `sshd_config` to function.
* **Root-cause only.** No retry-as-bandaid, no second gzip wrapper, no
  forking dartssh2 to change a constant we can live with.
* **Diagnosability.** Drop-cause telemetry, channel-open errors, and RTT
  samples already exist; unused signals are a waste, not a reason to add
  more rings.
* **macOS UI isolate.** Crypto and large gunzip on the Flutter main isolate
  freeze the chrome; work that can move to `compute` / `Isolate.run`
  should.
* **fail2ban / `PerSourcePenalties` / `MaxAuthTries`.** A reconnect loop
  that retries *authentication* failures is a lockout engine, not a
  robustness feature.

## Considered Options

* **A. Record findings only; pick items ad hoc as users report drops.**
* **B. Accept this assessment as the authoritative next-wave backlog**,
  with a recommended first tranche that stays inside the executor seam,
  and explicitly defer library-fork / SFTP / hardware-key / transport-
  compression work.
* **C. Raise every timeout and the read cap in one pass** (static
  widening: ping 30 s / 5, network timeout 10 min, read cap 8).
* **D. Triple-client plus a dartssh2 fork** (dedicated sync connection,
  larger channel windows, bounded rekey buffer) as the next commit.

## Decision Outcome

Chosen option: **"B. Accept this assessment as the authoritative next-wave
backlog"**, because the highest-leverage remaining defects are concentrated
and cheap relative to a library fork or a third long-lived client, and
because static widening (C) and a fork-first move (D) treat symptoms or
expand the blast radius before we have used the telemetry 0011 just
shipped.

The recommended **first tranche** (implement only after a paired PLAN is
approved) is T1–T8 below. **T3 is in that PLAN's scope** (maintainer,
2026-08-20), not deferred to telemetry. Everything else is recorded so
it is not re-discovered, not so it is built.

---

## Current engine: tunable inventory (fact)

All values are compile-time constants unless noted. None are user-facing
settings today.

| Knob | Value | Where | Why it is that number |
|---|---|---|---|
| dartssh2 pin | exact `3.3.0` | `pubspec.yaml` | 0013: 3.x is days old; `^` would absorb an unvetted 3.4 |
| Socket connect | 15 s | `SSHClientManager._socketTimeout` | Fail a black-holed SYN before the user thinks the app hung |
| `handshakeTimeout` | 15 s (same) | `SSHClient(...)` | Library-side cap on version/KEX; matches the socket |
| Auth timeout | 15 s, **pausable** | `_authTimeout` | Host-key prompt must not consume it |
| Stream-client auth | 10 s | `_streamAuthTimeout` | Best-effort; fail open to single-client |
| Library keepalive | `null` | `keepAliveInterval` | Fire-and-forget; 0011 owns reply-checked pings |
| Health ping interval | 15 s | `ConnectionHealthMonitor` | Below typical NAT/LB idle (60–350 s) |
| Ping reply timeout | 15 s | same | One slow RTT must not count as death |
| Failure threshold | 3 | same | ~45–60 s idle detection; 2 was too eager under compressed reads |
| Stream busy window | 30 s | `SSHCommandExecutor.streamBusyWindow` | Quiet `fswatch` is *idle*; recent bytes mean live |
| Command busy | `_activeCommands > 0` | `transportBusy` | Any in-flight request/response pauses probes |
| Stream redial | 15, 30, 60, 120, 120 s; 5 tries | `streamRedialDelay` | Structural MaxSessions=1 must not be hammered |
| Auto-reconnect | 1, 2, 4, 8, then 15 s × remaining; **20 attempts** (~4 min) then pause | `ConnectionController._reconnectDelays` / `_maxAutoReconnectAttempts` | Indefinite 15 s auth loops lock users out |
| Default command timeout | 60 s | `SSHCommandExecutor.defaultTimeout` | Status/log/diff/blame |
| Network timeout | 3 min | `GitService.defaultNetworkTimeout` | `fetch` / `push` / `pull` |
| Commit timeout | 5 min | `defaultCommitTimeout` | Hooks |
| Hook timeout | 30 min | `defaultHookTimeout` | `pnpm install` in a new worktree |
| Sideload timeout | 60 s + `bytes / 64 KiB/s` | `uploadTimeoutFor` | Slow-but-progressing must not lose to a flat 60 s |
| Retry backoff | 400 ms, **1** retry | `_retryBackoff`, `GitService._readRetries` | Idempotent reads only; allowlist |
| Read cap | 4 (hard clamp 8) | `CommandLaneScheduler` | 4 reads + 1 sync + 1 watcher + 1 CI ≈ 7 of MaxSessions 10 |
| Adaptive bands | no-sample **3**; &lt;80 ms → 4; 80–200 → 3; &gt;200 → 2; 3-sample hysteresis | `AdaptiveReadConcurrency` | High RTT: fewer concurrent gzip streams |
| Isolated cap | 2 | scheduler | Hooks must not pile up on the host |
| Watchdog margin | +30 s | `watchdogMargin` | Backstop; never the command's real timeout |
| Output budget | 50 MiB combined stdout+stderr, charged **post-gunzip** | `maxCommandOutputBytes` | Gzip bomb must not OOM |
| gzip | `-c -1`, absolute path | `CommandFormatter` | Fastest deflate; text diffs 5–10× |
| TERM→KILL grace | 400 ms | `killGrace` | Ignored TERM must not hold `.git/index.lock` |
| Proxy liveness | 5 s / 10 s / 2 misses | `ProxyCommandExecutor` | Child window vs dead main isolate |
| Watch coalescer | min 1 s, poll 5 s, recover 3 min | `watchLifecycle` | Two-stage coalesce + degrade-to-poll |
| dartssh2 channel window | **2 MiB** initial, **32 KiB** max packet | `ssh_client.dart:55–57` | Library constants; we do not pass them |
| dartssh2 rekey buffer | unbounded `_rekeyPendingPackets`; bypass only IDs 20–49 and ≤ 4 | `ssh_transport.dart:343, 1868–1872` | `SSH_MSG_GLOBAL_REQUEST` (80) still queued. 0011 busy-pause is the mitigation |
| OpenSSH MaxSessions | **10** (default) | `sshd_config(5)` | Informs the read cap, not a client setting |

### What dartssh2 3.3.0 already gave us (changelog, not our code)

* `SSHDisconnectError` — peer reason on `done` (we humanize it).
* Hang-forever fix (#212): unanswered channel/global-request waiters fail
  with the error that ended the connection. Our pings can no longer sit
  forever if the transport dies mid-probe.
* Receive-window replenish after a paused reader (#210). Slow UI drains
  no longer stall a channel for the rest of its life.
* RFC 4254 §5.2 limits: data beyond advertised max-packet or remaining
  window is rejected on **that channel only** (#213).
* Strict-kex, AES-GCM-first, `chacha20-poly1305@openssh.com` third,
  `ext-info-c` / `serverSigAlgs`.
* `flush()` on socket/client/channel (#185 / 2.22.2). **We never call it.**
* `waitForExit({Duration? timeout})`. **We call `waitForExit()` with no
  timeout** after a successful drain.
* `SSHIdentity` / `shouldProbe` / Secure Enclave. **Unused** (PEM in
  memory).
* SFTP 256 KiB packet cap and the historical `SftpClient.close()` channel
  leak fix (2.22.3). **We still sideload via `cat > path`.**

### Official OpenSSH / RFC facts that constrain us

* **RFC 4254 §5:** channels are window-flow-controlled independently.
  A saturated fetch channel should not stop a status channel *at the SSH
  layer*. Head-of-line we still see is **TCP + one dartssh2 transport
  mutex + rekey buffer**, not the window protocol.
* **RFC 4254 §5.1:** smaller max-packet is for interactive latency; we are
  a bulk+interactive multiplex and dartssh2's 32 KiB is already the RFC
  4253 receive floor. Do not ask for smaller packets.
* **`MaxSessions 10`:** session channels (exec/shell/subsystem), not
  TCP forwards. Dual client doubles the budget. A third client is still
  inside the default.
* **`MaxAuthTries 6`:** failures per *connection*. 20 reconnects are 20
  connections. OpenSSH ≥ 9.8 `PerSourcePenalties` (`authfail` default 5 s,
  accumulating to 10 min) will start refusing the laptop's IP.
* **`LoginGraceTime 120 s`:** our 15 s auth is well under. Do not raise it.
* **`ClientAliveInterval` default 0:** the *server* does not ping. If a
  remote enables it at 15 s / count 3, an unresponsive **client** is
  dropped in ~45 s — the same budget we use idle. OpenSSH **10.5**
  (2026-08-11) fixed ClientAlive math that sent probes *less* often than
  configured, and now sends ClientAlive during a time-based `RekeyLimit`.
  Recommend remotes stay on ≤ 60 s / ≥ 3; do not require 10.5.
* **`RekeyLimit` default `default none`:** 1–4 GiB, no time-based rekey.
  A clone/push crosses it; a status read does not. Busy-pause already
  covers the dartssh2 buffer stall *during* bulk. Time-based rekey on a
  remote (`RekeyLimit default 45m`) would rekey an *idle* session and
  could stall a ping — that is the remaining idle-rekey hole.
* **`ChannelTimeout` / `UnusedConnectionTimeout`:** default none. A
  remote that sets `session=5m` will kill a quiet `fswatch` channel
  without dropping the TCP connection. Operational note, not a client
  bug.
* **`TCPKeepAlive yes` (server):** spoofable, ~2 h idle on macOS clients.
  Useless against NAT drops measured in minutes. Still worth setting
  `SO_KEEPALIVE` on *our* socket as belt-and-suspenders for crash
  detection, not as the liveness path.
* **`Compression yes` (server):** irrelevant. dartssh2 offers `none` only
  (`ssh_transport.dart:1317–1318`). Application gzip stays.

---

## Remaining gaps (grounded)

These are the ARCHITECTURE_PLAN §0.1 "known gaps" plus what this pass
added. Severity is about user-visible failure or wasted capacity, not
implementation size.

### HIGH — first tranche candidates (T1–T8)

**T1. Classify reconnect failures (auth vs transport).**
`ConnectionController._autoReconnect` retries 20 times for *any* drop,
including `SSHAuthError` / `SSHHostkeyError`. On a password rotation,
revoked key, or fail2ban, that is 20 fresh TCP+auth handshakes against
`MaxAuthTries` and `PerSourcePenalties`. Pause immediately on
deterministic auth/host-key failures; keep the 20-attempt schedule for
`SocketException` / `SSHSocketError` / peer `SSHDisconnectError` that
look like network.

**T2. Progress-aware network timeout.**
`git fetch` / `push` use a 3-minute *wall* clock. A large pack on a
64 KiB/s link is killed while still moving; a wedged peer that opened a
channel and sent nothing is allowed the full 3 minutes. Sideload already
scales timeout with payload size (`uploadTimeoutFor`). The missing
primitive is an **activity deadline**: reset (or hold) the timer while
stdout/stderr bytes arrive; expire only after N seconds of silence
(suggest 60 s idle, 30 min absolute ceiling). Same pattern HTTP clients
use for downloads.

**T3. Dedicated sync-lane `SSHClient` (triple-client).**
Dual-client moved *streams* off the command connection. Fetch/push still
share that connection with up to 4 compressed reads and health pings.
RFC 4254 windows do not save us from one TCP congestion window and
dartssh2's single send path / rekey buffer. A third client used only by
`ExecLane.sync` lets status/diff keep flowing during a push, at the
cost of one more handshake and one more MaxSessions connection. Degrade
to dual (today's behaviour) if the sync client fails to auth — same
fail-open as the stream client — and redial it independently. In scope
for [0014-PLAN-ssh-engine-next-wave-hardening.md](./0014-PLAN-ssh-engine-next-wave-hardening.md).
Do not raise the read cap above 4 in that plan.

**T4. Feed `channelOpenErrors` into `AdaptiveReadConcurrency`; show the
cap.**
Errors are counted (`CommandTelemetry.recordChannelOpenError`) and never
consulted. A host with `MaxSessions 4` (or a degraded single-client
session under load) keeps trying to run 4 reads. Drop the cap on a
channel-open error (floor 1), raise slowly on a clean streak. Surface
`adaptiveReadCap`, `channelOpenErrors`, and dual/single on the dashboard
— §0.1 already listed this as missing.

**T5. Own the `dart:io` `Socket` before `SSHClient`.**
`SSHSocket.connect` (`ssh_socket_io.dart`) is `Socket.connect` with no
`setOption`. `SSHSocket` is an abstract class we can implement. Wrap our
own socket and set `SocketOption.tcpNoDelay` (disable Nagle — load-bearing
for small request/response multiplexed with bulk) and `SO_KEEPALIVE` if
the Dart SDK exposes it. Do **not** re-enable library `keepAliveInterval`.
Do **not** wait for an upstream `tcpKeepAlive` argument.

**T6. Offload `SSHKeyPair.fromPem` and large gunzip.**
`fromPem` runs as a constructor argument on the UI isolate
(`ssh_client_manager.dart` ~605). Encrypted PEM uses bcrypt; connect
janks the chrome. dartssh2 2.20 already offloads *KEX* via `Isolate.run`;
PEM decode is still ours. Large `gzip.decoder` of a 50 MiB diff is the
same class of freeze. `compute` / a dedicated parse isolate, generation-
guarded so a superseded connect does not attach a late key.

**T7. Sideload via `stdin.addStream` + `flush()`.**
`s.write(stdin)` then `stdin.close()` feeds the whole `Uint8List` in one
add. 0013 already recorded this as an independent 2.x/3.x optimization.
`addStream` plus `session.flush()` (2.22.2) lets flow control apply
*during* the upload instead of after a giant buffer, and matches the
timeout we already size at 64 KiB/s.

**T8. Reuse the environment probe across same-host reconnect.**
§0.1: auto-reconnect re-runs the PATH/`command -v` probe on the critical
path. OS and binary locations do not change because TCP dropped. Cache
`(host, port, username) → RemoteEnvironment` for the session lifetime;
invalidate on a successful connect to a *different* profile. Watcher
restart and UI refresh stay; the probe does not.

### MEDIUM — after T1–T8, or if telemetry points here

**T9. RTT-adaptive ping timeout** (0011 Option 3, deferred).
`max(15 s, 8 × median RTT)` with the existing `onPingSample` pipeline.
Only useful for *idle* detection on very high-latency links; busy-pause
already covers bulk. Do not build it to paper over a still-false monitor.

**T10. Compression admission.**
`gzip -1` is the right level (CPU vs ratio). The miss is *when* we pay
for a shell+pipe: `compress: true` is set on ~25 git reads plus glab/gh
JSON regardless of size. A 2 KiB porcelain status spends a process and a
round trip of gzip headers to save nothing. Gate on a cheap size hint
(known-small commands stay uncompressed) or on the previous sample's
ratio for that label. Keep `-1`; do not move to `-6`.

**T11. `waitForExit(timeout:)` after drain.**
Today the drain's `timeout` covers open→exit, then `waitForExit()` is
unbounded. If stdout/stderr close but the exit-status channel request
never arrives, 3.1.0 *should* fail the waiter when the channel dies —
still worth a short timeout (1–2 s) so a 3.x regression cannot wedge the
lane.

**T12. Migrate long-lived streams after a stream-client redial.**
§0.1: a watcher that opened while degraded stays on the command client
until its next restart. Not wrong; it just spends MaxSessions on the
hot connection. Nudge `watchLifecycle` to recycle on `streamClientDegraded`
flipping false.

**T13. Connect diagnostics on the dashboard.**
`client.strictKex`, `client.remoteVersion`, last `TransportDropSample`
(already recorded), current adaptive cap, gzip savings (already recorded).
No new probes — display what we already collect.

**T14. Operational guidance refresh.**
Keep 0011's remote recommendations. Add: do not set a short
`ChannelTimeout` on `session` if you want `fswatch` to live; be aware of
`PerSourcePenalties` if you fail-auth a laptop in a loop (T1 is the
client-side fix); OpenSSH 10.5 ClientAlive math is fixed if you rely on
server-side alive; leave `RekeyLimit` without a time component unless you
understand idle rekey vs our ping.

### LOW / explicitly deferred (do not smuggle into the first PLAN)

**D1. `SSHIdentity` / Secure Enclave / `shouldProbe`.** 0013 deferred.
Valuable; needs its own MADR (Keychain vs SE, UI for touch).

**D2. Switch sideloads to SFTP.** The 2.22.3 channel-close fix and 3.2.0
256 KiB cap make SFTP *safer* than when we rejected it. Exec-channel
`cat` still gives us lanes, generation, TERM→KILL, and no extra subsystem.
Revisit only with a dedicated decision.

**D3. Upstream dartssh2: bound `_rekeyPendingPackets`; let keepalive /
window / TCP options be constructor args.** File issues from the public
GitHub repo when we have write access. Do not fork to change
`_initialWindowSize = 2 MiB` — that value is already large (RFC 4254
allows up to 2^32−1; OpenSSH commonly uses ~2 MiB). A 32 KiB max packet
matches the RFC 4253 minimum receive size.

**D4. Transport compression.** Library still sends `none`. Application
gzip is the supported path. Do not negotiate zlib.

**D5. Re-enable library `keepAliveInterval`.** Still fire-and-forget;
would double global requests on the command client. 0011 closed this.

**D6. Raise the read cap above 4 without a third client.**
`maxReadCapHardLimit = 8` exists as a clamp, not a target. MaxSessions
headroom is the constraint, not Dart.

**D7. `client.run()` / `runWithResult()`.** Would drop byte budget, gzip
trailer, generation pin, and TERM→KILL. 0013 already forbade this.

**D8. Fish login-shell PATH mis-parse.** §0.1 known gap; common dirs still
covered. Not an SSH-engine defect.

---

## Creative ideas evaluated and rejected (or tightly scoped)

These were considered because the request asked for them. Recording the
rejection is the point.

| Idea | Verdict |
|---|---|
| Static ping 30 s / 5 failures | **Reject.** 0011 Option 2. Slows every idle death to ~2.5 min and still loses on a 1 Mbps return path. |
| Library keepalive *plus* our monitor | **Reject.** Doubles SSH_MSG_GLOBAL_REQUEST during bulk; library still does not check replies. |
| Time-based rekey on *our* side | **Cannot.** dartssh2 has no client `RekeyLimit`. Server-initiated only. |
| Smaller channel windows for "fairness" | **Reject.** RFC 4254 already isolates windows per channel. Shrinking ours adds WINDOW_ADJUST chatter and hurts bulk. |
| Larger windows via fork | **Defer (D3).** 2 MiB is already in the OpenSSH ballpark. |
| gzip `-6` / `--best` | **Reject.** Remote CPU on 4 concurrent reads is the scarce resource; `-1` is the correct point on the curve. |
| Skip gzip on LAN (RTT &lt; 5 ms) | **Maybe later, as part of T10.** LAN still has CPU and the shell wrapper; measure gzip savings on the dashboard first. |
| Happy Eyeballs / IPv6 | **No change.** `Socket.connect` already dual-stacks. T5 keeps that. |
| DSCP / `IPQoS` (`ef` vs `none`) | **Defer.** OpenSSH sets this on its own sockets; Dart's `Socket.setRawOption` is possible in T5 but unproven on macOS sandbox. Not first-tranche. |
| ControlMaster-style mux into one TCP | **Already what we do.** Dual/triple client is the *opposite* (isolation), and is the right opposite. |
| Auto-reissue superseded reads | **Reject.** 0011 deferred this to the UI refresh-on-reconnect, correctly. Silent replay across a generation bump is how you run a command on the wrong host. |
| Probe `MaxSessions` at connect (`sshd -T`) | **Reject.** Requires shelling a privileged command; fails on restricted accounts; the adaptive cap + channel-open errors (T4) observe the real budget. |
| Kill the 20-attempt reconnect entirely | **Too far.** 20 *network* tries over ~4 min is reasonable for a flaky VPN. T1 is classify, not delete. |
| Progress timeout with no absolute ceiling | **Reject.** A `git fetch` of an infinite remote would run forever. T2 needs both idle and ceiling. |

---

## Pros and Cons of the Options

### Option A: Record findings; fix ad hoc

* Good, because it writes nothing wrong into a PLAN.
* Bad, because T1 (auth-retry lockout) and T2 (3-minute pack kill) are
  already user-visible and will be re-discovered as "SSH is flaky."
* Bad, because the unused signals (`channelOpenErrors`, `flush`,
  `waitForExit` timeout, drop ring) will keep looking like missing
  features instead of unused wiring.

### Option B: Accept as next-wave backlog (chosen)

* Good, because it separates first-tranche seam work (T1–T8) from
  library/SFTP/hardware (D1–D8) so a PLAN can be small.
* Good, because it does not reopen 0011/0013 or the dartssh3 trap.
* Good, because every HIGH item is testable without `live-forge` (unit +
  existing `ssh_live_transport_test.dart`).
* Bad, because a backlog MADR can rot like 0004 if no PLAN follows.
* Neutral, because T3 (third client) is in the first PLAN's scope with a
  mandatory degrade-to-dual path; the read cap stays 4.

### Option C: Static widening of every timeout and the read cap

* Good, because it is a handful of constant edits.
* Bad, because it is 0011 Option 2 at larger scale: idle death slows
  down, MaxSessions pressure goes *up*, auth lockout (T1) is untouched.
* Bad, because a 10-minute fetch timeout still kills a slow pack and
  still waits 10 minutes on a wedged peer — the opposite of T2.

### Option D: Fork dartssh2 + triple-client as the next commit

* Good, because a bounded rekey buffer is the actual library bug, and a
  third client is a real HOL fix.
* Bad, because we do not have upstream write access, a fork is a
  permanent maintenance tax, and 3.3.0 is two days old — pinning an
  exact public release was the 0013 safety rail.
* Bad, because busy-pause already neutralises the rekey stall *during
  bulk*; forking to fix a mitigated bug delays T1/T2, which users hit
  without any rekey.

## Consequences

* Good, because the SSH engine has a current, numbered map of tunables
  and a ranked list of next moves, grounded in 3.3.0 source and OpenSSH
  10.5 docs rather than folklore.
* Good, because the first tranche stays inside `lib/core/ssh/` +
  reconnect + dashboard display — no service-layer redesign.
* Bad, because T3 (third client) has real complexity (another
  generation-pinned handshake, another health monitor, degrade path)
  and must not be treated as a one-line follow-on if a PLAN includes it.
* Bad, because we still cannot bound `_rekeyPendingPackets` ourselves
  without a fork; T2/T3 reduce how often it matters, they do not fix it.
* Neutral, because dartssh2 3.3.0 remains exactly pinned; this record
  does not bump the library.

### Confirmation

This decision holds when:

1. This file remains the ranked backlog until
   [0014-PLAN-ssh-engine-next-wave-hardening.md](./0014-PLAN-ssh-engine-next-wave-hardening.md)
   is explicitly approved. No source changes land from this MADR alone.
2. The PLAN that includes T3 also includes a degrade-to-dual path and a
   MaxSessions budget comment updated for the extra connection
   (command ≤4 reads + ≤2 isolated; sync 1; stream 1 watcher + 1 CI; each
   TCP still under default 10). Read cap stays 4.
3. Nothing in the first tranche re-enables `keepAliveInterval`, adopts
   `dartssh3`, switches uploads to SFTP, or raises `maxConcurrentReads`
   above 4 without T3 in the same change.
4. T1 is specified as an *allowlist of retryable reconnect errors*, not
   a denylist — matching `isTransientTransportError`.

## More Information

* Transport truth: [ARCHITECTURE_PLAN.md §0.1](./ARCHITECTURE_PLAN.md)
* Prior decisions: [0011](./0011-MADR-ssh-transport-stability-hardening.md),
  [0012](./0012-MADR-adopt-dartssh2-v3.md),
  [0013](./0013-MADR-prefer-dartssh2-v3-over-dartssh3.md)
* dartssh2 3.3.0 changelog:
  [pub.dev/packages/dartssh2/changelog](https://pub.dev/packages/dartssh2/changelog)
* dartssh2 3.3.0 source (pub-cache): `ssh_transport.dart:343` (rekey
  buffer), `:1868` (bypass), `ssh_client.dart:55` (2 MiB window),
  `ssh_socket_io.dart` (no `setOption`)
* OpenSSH: [sshd_config(5)](https://man.openbsd.org/sshd_config.5),
  [10.5 release notes](https://www.openssh.com/txt/release-10.5)
* RFC 4254 §5: [rfc-editor.org/rfc/rfc4254](https://www.rfc-editor.org/rfc/rfc4254.html)

Implementation plan:
[0014-PLAN-ssh-engine-next-wave-hardening.md](./0014-PLAN-ssh-engine-next-wave-hardening.md)
(T1–T8, T3 in scope). Execution starts only after that plan is
explicitly approved.
