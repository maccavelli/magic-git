---
status: "proposed"
date: 2026-09-04
decision-makers: [Maintainer]
consulted: []
informed: [Magic Git contributors]
verified: 2026-09-04
---

# Treat the 2026-09-04 SSH / remote-repo engine debug pass as the current prioritized remediation backlog

## Context and Problem Statement

The SSH transport is the load-bearing path for every remote feature in Magic
Git. It has been hardened repeatedly —
[0011](0011-MADR-ssh-transport-stability-hardening.md) (busy-pause liveness),
[0013](0013-MADR-prefer-dartssh2-v3-over-dartssh3.md) (dartssh2 3.3.0),
[0014](0014-MADR-ssh-engine-next-wave-hardening.md) (next-wave backlog),
[0018](0018-MADR-transport-readiness-is-not-an-error.md) (readiness as a
state), [0020](0020-MADR-fetch-pull-push-lag.md) (lane scheduling, streamed
progress) — and most of what a reader would expect to find broken is not
broken. The generation pinning is real, the byte budget exists, the health
monitor counts *answered* pings, the lane scheduler has a watchdog.

That maturity is exactly why a fresh pass is worth running, and why its
findings look different from the earlier ones. What remains is not missing
machinery. It is machinery that is **present, documented, and does not do what
its own documentation says it does**:

* a readiness gate that stops gating the moment two connects overlap;
* a byte budget that cannot bound the one code path whose comment claims it
  is the reason the budget is charged where it is;
* a congestion controller whose input is structurally unable to observe
  congestion;
* a `MaxSessions` budget written down in a comment that omits an entire class
  of channel;
* a stream whose stderr nothing reads, on a library whose controller buffers
  it forever.

Each of these reads as correct on inspection. Each fails only in a state the
code already anticipates elsewhere. That is the class of defect that survives
five hardening passes, and it is what this record catalogues.

## Audit method

Read-only, and every claim below is anchored to a file and line in the tree at
`21721ef` (`master`, clean). No source was modified.

Three kinds of evidence appear, and they are labelled distinctly because they
carry different weight:

* **Read** — the claim follows from the code as written, cited by
  `file.dart:NNN`.
* **Reproduced** — the behaviour was executed and observed. Reproductions ran
  as standalone Dart programs in a scratch directory, transcribing the
  function under test verbatim (the transcription is quoted in the finding so
  it can be checked against the source). Nothing was written into `test/` and
  the working tree was never dirtied — per `AGENTS.md`, a negative test that
  mutates the tree is not evidence.
* **Library-verified** — the claim depends on dartssh2 3.3.0 behaviour and was
  checked against the pinned package source in `~/.pub-cache`, cited by file
  and line.

Areas covered: `lib/core/ssh/` (all 9 files), `lib/core/exec/` (all 10),
`lib/core/git/` transport-facing members (`remote_watch_service.dart`,
`bounded_watch.dart`, `watch_lifecycle.dart`, `host_fs_service.dart`,
`git_cat_file_batch.dart`), and the connection lifecycle in
`lib/core/providers/app_providers.dart`.

## Relationship to earlier records

Nothing here contradicts a shipped decision. Two findings sharpen one:

* **H1 is a defect in 0018's implementation, not in 0018.** The readiness
  contract is right; the completer bookkeeping under it has an aliasing bug.
* **M1 is a defect in 0011/0014's implementation of busy-pause.** Pausing
  probes while busy is correct for liveness — it is the reason a fetch is not
  killed. The bug is that the *same* probe was later reused as the input to a
  congestion controller, where "never sampled under load" is disqualifying.

H2 touches a boundary 0022 M10 already worked on (the cat-file base64 batch)
but is a different defect in a different layer.

## Scope

In scope: the SSH transport, the executor seam, lane scheduling, the remote
watcher, and the remote-repo lifecycle (connect, reconnect, scope
registration, host filesystem).

Out of scope: forge CLI semantics (0019, 0021, 0022), UI surfaces, the local
backend except where it establishes parity, and anything requiring a live host
to observe. Two findings (M2, M3) name a live-host confirmation step because
their failure mode cannot be produced offline; they are stated as **Read**,
not as measured.

## Decision Drivers

* **A comment that lies is worse than no comment.** Four findings here are
  cases where the code carries a confident explanation of a safety property it
  does not have. A future maintainer reads the comment and stops looking.
* **Silent degradation is the enemy of a remote tool.** The user cannot see
  the host. A watcher that quietly becomes a poller, a read cap that quietly
  pins itself to 2, a session that quietly exceeds `MaxSessions` — each
  presents as "the app feels slow today" with nothing to chase.
* **Latency is the product.** This is a client for repositories the user
  cannot reach any other way, often over links where RTT dominates. Round
  trips are the currency; two of them per command is not a detail.
* **Fix causes, not symptoms** (`AGENTS.md`). A1 and A2 below replace
  mechanisms rather than tuning their constants, because the constants are not
  what is wrong.

## Considered Options

* **Option A — Ship this as a prioritized backlog, remediate in a paired
  PLAN.** One record, findings ranked, each with a named resolution and a
  confirmation step; execution gated on maintainer approval.
* **Option B — Fix the high-severity items immediately and record the rest as
  a wish list.** Faster to a safer tree; abandons the medium tail, which is
  where the silent-degradation findings live.
* **Option C — Open one record per finding.** Precise citation; nine records
  for one afternoon's reading, and `docs/README.md` becomes unreadable.
* **Option D — Do nothing; the engine is stable in practice.** Defensible on
  observed uptime, and wrong on inspection: H2 and H3 are unbounded-memory
  paths, and H1 defeats a decision already taken and paid for.

## Decision Outcome

Chosen option: **"Option A — ship as a prioritized backlog"**, because the
findings are heterogeneous in severity but homogeneous in kind (present
machinery that misbehaves in a documented-but-unhandled state), and that shape
is what a single ranked record serves best. It also matches the precedent set
by [0022](0022-MADR-git-gh-glab-engine-debug-audit.md), which is now the house
form for an engine-wide pass.

Adopted with it, as decisions rather than suggestions:

1. **A safety property gets a test that has been seen to fail, or it is not
   considered fixed.** H1, H2 and H3 are all cases where the property was
   asserted in prose and never exercised. Every remediation below names the
   negative test that must be watched to fail first, per `AGENTS.md`.
2. **The `MaxSessions` budget stops being a comment and becomes a counter.**
   M2's real defect is that the budget lives only in prose in
   `command_lanes.dart:118-127`; streams were simply forgotten when it was
   written, and nothing could have caught that.
3. **Where an algorithm's input cannot observe the thing it controls, replace
   the input, not the thresholds** (A2).

No code changes accompany this record. Per the global workflow, implementation
waits on a completed `0024-PLAN-ssh-and-remote-repo-engine-debug-audit.md` and
explicit approval to execute.

### Consequences

* Good, because the two unbounded-memory paths (H2, H3) are named with the
  exact line that removes the bound, so neither needs re-deriving.
* Good, because H1 arrived with a reproduction rather than an argument, so the
  fix can be validated against a failing case that exists today.
* Good, because A1 is a measured 150× on the UI isolate for a ~10-line change
  with no behavioural surface — the cheapest item in the record.
* Bad, because P2 (command batching) is a genuine architectural change to the
  executor seam and cannot be landed incrementally without a feature flag; it
  is proposed here, not committed to.
* Bad, because M2 and M3 rest on reading and want a live-host confirmation
  that this pass could not perform. They are ranked below the reproduced
  findings for that reason.
* Neutral, because nothing here changes a public API or a persisted format;
  every remediation is internal to `lib/core/ssh/`, `lib/core/exec/`, or
  `lib/core/git/remote_watch_service.dart`.

## Findings

Severity is user impact, not effort. **H** = data loss, unbounded memory, or a
shipped decision defeated. **M** = silent degradation the user cannot diagnose.
**L** = cosmetic or defensive.

### HIGH

#### H1 — `withAttachGate` settles the *successor's* gate, so overlapping connects defeat MADR 0018's readiness contract

**Evidence: Reproduced.**

`lib/core/ssh/ssh_client_manager.dart:393-401`:

```dart
Future<T> withAttachGate<T>(Future<T> Function() body) async {
  if (!_attachGate.isCompleted) _attachGate.complete();
  _attachGate = Completer<void>();
  try {
    return await body();
  } finally {
    if (!_attachGate.isCompleted) _attachGate.complete();
  }
}
```

The `finally` re-reads the **field**, not the completer this invocation
installed. With two connects in flight, the field no longer holds the first
one's gate:

1. Connect **A** starts. It completes nothing, installs gate `G_A`.
2. Connect **B** starts. It completes `G_A` (correct — A is superseded) and
   installs `G_B`.
3. A's body returns — immediately, via one of `_connect`'s supersession
   early-returns (`ssh_client_manager.dart:429`, `:501`, `:513`). Its
   `finally` reads `_attachGate`, finds `G_B`, and **completes B's gate while
   B's handshake is still running.**

From that moment `isAttachSettled` (`:352`) is `true` and `attachSettled`
(`:347`) is already resolved. The readiness gate in `_run`
(`ssh_command_executor.dart:724-726`) and in `executeStream` (`:1082-1084`) is
written as:

```dart
if (!_clientManager.isAttached && !_clientManager.isAttachSettled) {
  await _clientManager.attachSettled.timeout(attachGrace, onTimeout: () {});
}
```

so it falls straight through and every command issued during B's handshake
throws `SSHTransportNotReady` — the precise outcome
[0018](0018-MADR-transport-readiness-is-not-an-error.md) exists to prevent, in
the precise state ("a handshake *is* in flight") it exists to handle.

Reproduction, transcribing `withAttachGate` verbatim (the transcription was
diffed against the source; it is byte-identical):

```
after A starts      -> isAttachSettled=false  (expect false)
after B starts      -> isAttachSettled=false  (expect false)
after A returns     -> isAttachSettled=true   (expect false; B still handshaking)
command waited for handshake? false           (expect true)
after B returns     -> isAttachSettled=true   (expect true)
```

**How overlapping connects happen in production.** `_autoReconnect`
(`app_providers.dart:2045-2086`) awaits each `reconnect()`, so the loop alone
never overlaps. The overlap is user-driven and ordinary: the reconnect popup
is up, attempt *N* is mid-handshake, and the user picks a different saved
connection from the switcher or taps reconnect. `stopReconnect`
(`:2090`) bumps `_attempt` and calls `disconnect()`, but `disconnect()`
(`ssh_client_manager.dart:932`) does not touch `_attachGate` at all — so the
window is entered through the plain second `connect()`.

**Blast radius.** Not corruption: `connect` invalidates every repo family, so
the affected reads are re-issued once the session settles. The cost is that
the panes render the not-ready state (and, across the pop-out relay — 0022
Phase 1 — the child window does too) for the length of a handshake, in the one
scenario where the user is already watching a reconnect and least tolerant of
it.

**Resolution.** Bind the completer to the invocation:

```dart
if (!_attachGate.isCompleted) _attachGate.complete();
final gate = _attachGate = Completer<void>();
try {
  return await body();
} finally {
  if (!gate.isCompleted) gate.complete();
}
```

**Negative test that must be seen to fail:** two overlapping
`withAttachGate` calls; assert `isAttachSettled` is `false` after the first
returns. Against today's code it must fail. `test/transport_readiness_race_test.dart`
already drives `withAttachGate` (`:57`, `:96`, `:113`) but only ever with one
in flight, which is why this survived.

#### H2 — The output byte budget cannot bound a *compressed* read, and the comment above it claims the opposite

**Evidence: Read.** `lib/core/ssh/ssh_command_executor.dart:875-888`:

```dart
if (compressed) {
  stdoutFuture = () async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in rawStdout) {   // <- no budget, no bound
      builder.add(chunk);
    }
    final wire = Uint8List.fromList(builder.takeBytes());
    stdoutWireBytes = wire.length;
    final raw = await gunzipStdout(wire);    // <- full decompression
    budget.charge(raw.length, label);        // <- bound applied AFTER the fact
    ...
```

The uncompressed branch immediately below (`:889-899`) wraps its stream in
`boundedBytes(...)`, which charges every chunk *before* yielding it
(`command_drain.dart:69-78`) and therefore aborts mid-stream. The compressed
branch has no such wrapper. It:

1. accumulates the entire gzip stream in a `BytesBuilder` with no ceiling;
2. materialises it as one `Uint8List` (a second full copy);
3. decompresses all of it — into a third buffer, off-isolate above 256 KiB
   (`gunzipStdout`, `:665`);
4. and only then asks whether it was allowed to.

`budget.charge` cannot prevent an allocation that has already happened. By the
time `SSHOutputExceeded` is thrown the peak has been paid, and `utf8.decode` at
`:885` is reached only if the budget passes — but the three buffers above it
are not.

The comment at `:865-872` states the intent that is not achieved: *"For a
compressed read, stdout is gunzipped **before** the budget so the cap bounds
what this process actually buffers (the decompressed size) — the wire saving is
the point, but a gzip bomb must not be."* Charging after decompression bounds
what is *reported*, not what is *buffered*.

**Reach.** 27 call sites pass `compress: true` (`glab_service.dart:728`,
`gh_service.dart:607`/`:1295`, `git_cat_file_batch.dart:192`, and 23 in
`git_service.dart`). The sharpest is the cat-file batch: it base64-encodes blob
content on the host (`+33%`), and base64 of already-compressed or binary
content does not re-compress, so wire ≈ decompressed ≈ 1.33× the raw blob set,
with the decoded `String` costing another 2 bytes/char. A single large binary
blob in a diff request is enough. The `maxBytes` guard that exists elsewhere
(`git_service.dart:2940`, `:3034` — 12 MiB) is not on this path.

**Resolution.** Charge the wire bytes as they arrive — a *wire* budget bounding
the compressed stream — and keep the post-gunzip charge as the second gate. The
two limits are different numbers and both are needed: the wire budget stops the
bomb, the decompressed budget stops the merely-enormous.

**Negative test that must be seen to fail:** feed a synthetic gzip stream whose
wire size exceeds the wire budget but whose *declared* decompressed size is
small, and assert `SSHOutputExceeded` before the accumulate completes.

#### H3 — The remote watcher never reads its stderr: diagnostics are discarded and dartssh2 buffers the unread stream for the life of the session

**Evidence: Read + Library-verified.**

`RemoteWatchService.watch` subscribes to stdout only —
`remote_watch_service.dart:185` (`handle.stdout.listen(...)`). There is no
reference to `.stderr` anywhere in that file. Every other `executeStream`
caller does consume it: `glab_service.dart:1033`
(`errSub = newHandle.stderr.listen(...)`), and the clone controller
(`clone_controller.dart:239`).

Two independent consequences.

**(a) The diagnostic is lost.** `inotifywait` reports per-directory failures on
stderr — canonically `Failed to watch <dir>; upper limit on inotify watches
reached` when `fs.inotify.max_user_watches` is exceeded — and so do `fswatch`
and the bounded scripts. None of it reaches the app. The user observes only
that the watcher "didn't arm", which `watchLifecycle` converts to three
retries (`watch_lifecycle.dart:112`, `maxRestarts = 3`) and then a permanent
polling fallback with a three-minute recovery probe. The one message that says
*why*, and that names the `sysctl` the user would change, is dropped on the
floor. This is the highest-value failure in the whole watcher and it is the
one that is invisible.

This matters most in exactly the configuration the bounded-watch work
(0022 H5) was built for: a scoped dotfiles repo whose work tree is `$HOME`.

**(b) The unread stream is buffered without bound.** dartssh2 3.3.0,
`lib/src/ssh_session.dart:74-77`:

```dart
late final _stderrController = StreamController<Uint8List>(
  onPause: _pauseChannelData,
  onResume: _resumeChannelData,
);
```

A single-subscription `StreamController` with **no listener** queues every
`add` internally and never applies back-pressure — `onPause`/`onResume` only
engage once a subscription exists. Incoming stderr is added unconditionally at
`:176-177`. In `_SshSessionStreamHandle` the `stderr` getter is `late final`
(`ssh_command_executor.dart:177`), so if nothing reads it the decode is never
even constructed and the raw controller queue simply grows.

The watcher session is the longest-lived channel in the app — hours or days.
Under (a), where a large watch set produces one stderr line per failing
directory, (b) turns a lost diagnostic into a steady heap leak.

**Resolution.** Subscribe to `handle.stderr` in `RemoteWatchService.watch`;
route it to the output log at info level, bounded to the first N lines per arm
so a pathological watcher cannot flood it; and detect the watch-limit
signature specifically so the UI can say what to raise. Cancel the
subscription in the `WatchArmed` teardown alongside `sub` and `handle`
(`remote_watch_service.dart:232-240`).

**Negative test that must be seen to fail:** a fake `CommandStreamHandle`
emitting the inotify limit line on stderr; assert it reaches the log and sets
the diagnostic. Against today's code nothing is emitted.

### MEDIUM

#### M1 — The adaptive read cap is a congestion controller whose input is only ever sampled while the link is idle

**Evidence: Read.** `AdaptiveReadConcurrency` (`adaptive_read_concurrency.dart`)
exists to lower read concurrency when the link is loaded or high-latency. Its
only input is `onRtt`, fed from `noteLinkRtt`
(`ssh_command_executor.dart:379`) ← `ConnectionHealthMonitor.onPingSample`
(`ssh_client_manager.dart:116`).

That callback is unreachable while the transport is working. `_probe`
(`ssh_client_manager.dart:104-127`):

```dart
if (isBusy?.call() ?? false) {
  _failures = 0;
  return;                // <- no ping sent, so no sample
}
```

and `isBusy` for the command client is `commandBusy` = `_activeNonSync > 0`
(`ssh_command_executor.dart:339`, wired at `:350-354`). So **a sample is taken
only when no command is in flight** — the one condition under which read
concurrency does not matter. The controller adapts to the link's idle RTT and
is structurally blind to the load it is meant to shed.

The busy-pause itself is correct and must stay: it is 0011's fix for the
monitor killing a healthy-but-busy session. The defect is reusing that probe as
a control input.

Two smaller defects in the same class:

* The doc comment says *"Band thresholds (median RTT)"*
  (`adaptive_read_concurrency.dart:43`) but `onRtt` bands a **single** sample
  (`:66`). No median is computed anywhere. Hysteresis
  (`consecutiveRequired = 3`) damps thrash but does not make it a median: one
  outlier resets `_pendingCount` (`:77-81`) and can indefinitely postpone a
  legitimate change.
* With samples arriving only every 15 s of *idle*, an actively-used session
  may never accumulate three consecutive in-band samples at all, and the cap
  stays pinned at `noSampleCap = 3` for the whole session — below the
  ceiling of 4 the scheduler is budgeted for.

**Resolution.** See **A2**. This is not a threshold-tuning bug.

#### M2 — Stream channels have no admission control and are absent from the `MaxSessions` budget

**Evidence: Read.** The budget is prose, in `command_lanes.dart:118-127`:

```
//   command: ≤4 reads (+ exclusive is a barrier) + ≤2 isolated
//   sync:    1 fetch/push (scheduler: one at a time)
//   stream:  1 watcher + 1 CI trace
// Degraded dual (no sync client): command carries 4 reads + 1 sync + ≤2 isolated.
```

Two things it does not account for.

*Streams are unbounded and unscheduled.* `executeStream`
(`ssh_command_executor.dart:1056`) deliberately bypasses the scheduler — right,
since a never-exiting command would wedge a lane — but nothing else caps it
either. `_activeStreams` is incremented (`:1115`) and decremented
(`:370-372`) purely for the `streamBusy` liveness probe; it is never consulted
as a limit. `repoWatchProvider` is `.family` by repo path
(`app_providers.dart:3361`), so each distinct watched repo arms its own
channel — the active repo, plus each pop-out window's subscription
(`window_manager_bridge.dart:354`), plus `jobTraceProvider` (`:5015`) per
traced job.

*The degraded path routes streams onto the command client.* The `streamClient`
getter falls back to `_client` (`ssh_client_manager.dart:304`), and
`syncClient` likewise (`:311`). In fully-degraded single-client mode — a host
that refuses additional *connections* (`MaxStartups`, auth rate limiting), so
both best-effort handshakes fail at `_connect:437`/`:461` — the one TCP
connection carries 4 reads + 2 isolated + 1 sync + every watcher + every
trace. That reaches OpenSSH's default `MaxSessions 10` at three streams, and
the comment's "degraded dual" arithmetic (7) never mentions them.

The consequence is not a crash. `SSHChannelOpenError` is transient
(`isTransientTransportError:634`), so reads retry and the adaptive floor drops
(`onChannelOpenError`) — the session silently contracts to a cap of 1 while
watchers flap into polling, with the cause visible only as a telemetry counter.

**Resolution.** Make the budget an enforced number rather than a comment: a
per-client channel accounting shared by the scheduler and `executeStream`, with
streams admitted against it and a defined policy when the budget is exhausted
(refuse the newest stream and degrade *that repo* to polling with a stated
reason, rather than letting the whole session contract).

**Confirmation requires a live host** — set `MaxSessions 4` on a test sshd,
open three watched repos, and observe. This is stated as Read, not measured.

#### M3 — `_detectWatcher` reads a failed command as "this host has no watcher", and caches it

**Evidence: Read.** `remote_watch_service.dart:244-268` runs a
`command -v` probe and switches on `result.stdout.trim()`, with `default:
return RemoteWatcherTool.none`. `result.isSuccess` is never consulted, and the
call passes no `retries`. Any failure that yields empty stdout — a transient
channel-open error, an `SSHTransportNotReady` mid-reconnect, a `cd` failure
because the repo path is briefly unavailable — is indistinguishable from a
host that genuinely has neither tool.

The answer is then cached for the stream's life (`:143`,
`cachedTool ??= await _detectWatcher(repoPath)`) and cleared only by
`onPollingRecoveryAttempt` (`:141`), which fires on the
`recoveryInterval` — three minutes by default (`watch_lifecycle.dart:110`). So one transport blip
at arm time costs three minutes of five-second polling on a host that has a
perfectly good `fswatch`.

**Resolution.** Distinguish the two: on `!result.isSuccess`, do not cache and
do not return `none` — surface it as an arm failure so `watchLifecycle`'s
restart budget (which exists for exactly this) retries in seconds rather than
minutes. Reserve `none` for a *successful* probe that printed `none`. Give the
probe `retries: 1`, which is safe — it is idempotent and read-only.

#### M4 — The connect probe writes to a guessable `/tmp` path through a plain redirect

**Evidence: Read.** `environment_probe.dart:284-291`:

```
'_mg_lp="${TMPDIR:-/tmp}/mg_lp.$$"; '
'(${SHELL:-sh} -lc \'printf %s "$PATH"\' >"$_mg_lp" 2>/dev/null) & '
```

`$$` is the PID of the probe's shell — guessable, and brute-forceable within
the PID space. A plain `>` follows symlinks, and `/tmp` is world-writable
(the sticky bit prevents deleting another user's file, not creating a new name).
On a shared host, another local user can pre-plant
`/tmp/mg_lp.<pid> -> ~/.ssh/authorized_keys` and have the probe truncate it
and write a `PATH` string into it, under the connecting user's own uid.

The impact is truncation of an arbitrary file the user can write, not
disclosure; the file's content becomes a `PATH`. It is low likelihood and
requires a shared host. It is listed because **the codebase already holds the
opposite standard, for this exact reason**:
`git_service.dart:3315-3321` uses `mktemp` for the commit-message preview and
documents why — *"a fixed filename here would let another local user (or a
second, racing invocation of this same call) pre-plant a symlink or a file at
that path."* The same argument applies verbatim here and was not applied.

**Resolution.** `mktemp`, matching `generateCommitMessage`. See also **P1**,
which removes this file from the connect path entirely.

### LOW

#### L1 — `NativeSshSocket.connect` leaks the socket if `tcpNoDelay` throws

`native_ssh_socket.dart:28-31`: `Socket.connect` succeeds, then
`applyTcpOptions(socket)` runs. Inside it (`:41`) `setOption(tcpNoDelay)` is
deliberately *outside* the `try` that guards the best-effort `SO_KEEPALIVE`
(`:42-52`). If it throws — a socket closed by the peer between connect and
setOption is the realistic case — the exception propagates out of `connect()`
with the socket neither closed nor destroyed. One leaked FD per occurrence,
and `connect` is retried up to 20 times by `_autoReconnect`.

**Resolution.** Wrap the body so any failure destroys the socket before
rethrowing.

#### L2 — `CommandLaneOverrun` has no humanizer arm, so its developer text can reach the UI

`humanizeSshError` (`ssh_error_messages.dart:64-135`) covers
`SSHCommandTimeout`, `SSHCommandSuperseded`, `SSHTransportNotReady` and
`SSHOutputExceeded`, but not `CommandLaneOverrun`, whose `toString()`
(`command_lanes.dart:69-76`) is a two-sentence developer note ending *"This is
a bug in the command executor, not a slow command — it should have timed out on
its own well before this."* It falls through to the generic tail. This is the
same leak class 0018 was written to close.

It should be rare by construction — but "rare" is the argument that left the
watchdog unenforced until it was added, and the string is worse than the ones
0018 rewrote.

**Resolution.** One arm: *"A command did not finish and was abandoned. Try
again."*

## Performance

Two proposals, both aimed at latency rather than throughput, because RTT is
what this app spends.

### P1 — Take the login-shell PATH capture off the connect critical path (up to 3 s per connect, ×20 per reconnect storm)

**Evidence: Read.** `environment_probe.dart:284-291` blocks the connect-time
probe on a background login shell:

```
'i=0; while [ $i -lt 30 ] && kill -0 $lp_pid 2>/dev/null; do '
'i=$((i+1)); sleep 0.1; done; '
```

Up to **3 seconds**, in 30 iterations that each fork `sleep`. This sits at
`app_providers.dart:1365` (`_resolveEnvironment`), between the handshake and
`validateRepoPath` (`:1419`), i.e. strictly before `connected` is published and
the UI becomes usable. `reconnect()` re-pays it on every attempt, and
`_autoReconnect` allows twenty (`:2043`).

The payoff is small and mostly redundant. The capture exists to pick up a
`brew shellenv` line in a user's `.zshrc` — but the script already hardcodes
`/opt/homebrew/bin`, `/opt/homebrew/sbin`, `/usr/local/bin`, `/usr/local/sbin`
for Darwin and the linuxbrew path for Linux (`:299-303`), which is what that
`shellenv` line adds. The 3 s is paid by every user to cover the residue.

**Proposal.** Emit the probe's answer immediately with `lp=""` and reconcile
the login-shell PATH in the background pass that already exists —
`probeVersions` runs post-connect off the critical path (`:1623`) and is the
natural home. If the login shell contributes directories the augmented PATH
lacks, call `configureEnvironment` again; nothing in the executor caches PATH
beyond that field (`ssh_command_executor.dart:388-391`). Removes the busy-wait,
the 30 `sleep` forks, and — with it — M4's temp file.

**Expected:** connect and every reconnect attempt shorter by up to 3 s;
typically ~0.1–0.5 s on a fast host with a light shellrc, the full 3 s on a
heavy one. Measurable directly: `timings.elapsedMilliseconds` is already
captured at `app_providers.dart:1367` (`envMs`).

### P2 — Batch same-window read commands into one channel: every `execute()` costs two round trips before the command starts

**Evidence: Library-verified.** `SSHCommandExecutor._runBody` issues
`client.execute(command)` (`:839`) per command. In dartssh2 3.3.0,
`SSHClient.execute` (`lib/src/ssh_client.dart:502`) does:

1. `_openSessionChannel()` (`:510`) → `_openChannel` (`:1652`), which awaits
   `CHANNEL_OPEN_CONFIRMATION` (`:1663`) — **one RTT**;
2. `sendExec(command)` with `wantReply: true`
   (`lib/src/ssh_channel.dart:90-98`), awaiting `CHANNEL_SUCCESS` — **a second
   RTT**.

So **two full round trips of protocol overhead per command**, before a byte of
`git` runs, plus a remote `sh -c` fork (`CommandFormatter.format` wraps every
invocation).

The fan-out that makes this expensive is already in the codebase.
`repoMutationFamilies` (`app_providers.dart:2912-2935`) invalidates 12
families after every stage/commit; `repoScopedFetchFamilies` (`:2788-2851`)
invalidates **55** on ⌘R, connect and disconnect. Each live family whose
provider is being watched re-fetches as its own `execute`. At a 200 ms RTT
with the read cap at 4, twelve commands is three waves × 400 ms ≈ **1.2 s of
pure channel-open overhead** after a commit; a ⌘R with thirty live providers is
nearer 3 s of it.

**Proposal.** A batching layer in front of the read lane. Collect
`ExecLane.read` commands issued within a short window (~15–25 ms, one frame),
cap the batch (~8), and emit them as a single `sh -c` script that runs each in
sequence and frames the results with length prefixes — then demultiplex to the
individual futures. Two round trips are amortised across the batch instead of
paid per command; the remote pays one `sh` fork instead of *n*.

This is not a new idea in this codebase — it is the generalisation of
`GitCatFileBatch` (`git_cat_file_batch.dart`), which already does exactly this
for blobs, including the fail-open-to-individual-calls posture
(`git_cat_file_batch.dart:156-157`) that makes it safe.

**Constraints that must be respected, and are why this needs a plan:**

* **Reads only.** Never `exclusive` (the barrier is the `.git/index.lock`
  guarantee) and never `sync`.
* **Head-of-line blocking inside a batch is real.** One slow member delays its
  batch-mates. Cap the batch and give it a single deadline; on overrun, fail
  the batch and let `runWithRetries` re-issue members individually.
* **The byte budget becomes per-batch.** Framing must charge each member
  separately or a single large read starves the rest — and see **H2**, which
  must be fixed first, since batching multiplies the compressed path's
  exposure.
* **Cancellation gets harder.** A cancelled member cannot kill the channel its
  batch-mates are using.

Flag-gated, off by default, with the per-command path retained.

## Algorithms

### A1 — The watcher's record split is quadratic in the arriving chunk; an index cursor makes it linear (measured 150×)

**Evidence: Reproduced.** `remote_watch_service.dart:186-201`:

```dart
buffer += chunk;
var idx = buffer.indexOf(delimiter);
while (idx >= 0) {
  final event = buffer.substring(0, idx);
  buffer = buffer.substring(idx + 1);   // full copy of the remainder, per record
  ...
  idx = buffer.indexOf(delimiter);      // rescans from 0, per record
}
```

Every record copies the entire remaining buffer and restarts the scan at
offset 0. For *k* records in a buffer of *n* chars the work is Θ(n·k) — with
records of roughly fixed width, **quadratic in the size of the arriving
chunk**. The 1 MiB guard at `:219-227` does not bound it: that check runs
*after* the `while` loop has already drained every complete record, and only
limits the undelimited remainder.

Chunk size is set by the transport: dartssh2 3.3.0 negotiates
`_maximumPacketSize = 32768` (`lib/src/ssh_client.dart:57`), so ~32 KiB per
listener invocation is the realistic case. Measured, transcribing both loops
and feeding identical input as 32 KiB chunks with the leftover carried across
exactly as the real code does:

| burst (events) | chunks | current | index cursor |
|---:|---:|---:|---:|
| 5,000 | 6 | 33.3 ms | 0.2 ms |
| 20,000 | 24 | 133.7 ms | 0.9 ms |
| 60,000 | 73 | **400.6 ms** | **1.9 ms** |

At a hypothetical 256 KiB packet size the same 60,000-event burst costs 2.1 s
versus 2.3 ms — recorded to show the scaling, not as the shipped configuration.

This runs in a `Stream.listen` callback on the **UI isolate**. A 60,000-event
burst — `git checkout` across a large branch, a `git clean`, a dependency
install inside the work tree — is ~400 ms of dropped frames, in the one code
path whose entire job is to make the app feel live.

**Proposal.** Scan with an integer cursor and slice once:

```dart
buffer += chunk;
var start = 0;
var idx = buffer.indexOf(delimiter, start);
while (idx >= 0) {
  final event = buffer.substring(start, idx);
  start = idx + 1;
  ... // unchanged: relativize, shouldTriggerWatch, signalPath, re-arm
  idx = buffer.indexOf(delimiter, start);
}
buffer = start == 0 ? buffer : buffer.substring(start);
```

Identical emitted records; one remainder copy per chunk instead of one per
record. ~10 lines, no behavioural surface, no new state. It is the cheapest
item in this record by a wide margin, and `remote_watch_service.dart` is the
only file in `lib/` carrying this shape (`local_watch_service.dart` parses
per-event and does not accumulate).

**Negative test that must be seen to fail:** feed a chunk whose records
straddle chunk boundaries and assert the emitted sequence; then assert a
timing bound on a 20,000-event burst. The correctness half passes today —
which is the point: this is a pure performance defect behind a correct
implementation, and only the timing assertion can fail first.

### A2 — Replace the open-loop RTT-band lookup with a closed-loop limiter driven by data the app already collects under load

**Evidence: Read.** `AdaptiveReadConcurrency` is a three-bucket lookup table
over a single instantaneous sample — `bandForRtt` (`:47-52`): `<80 ms → 4`,
`80–200 ms → 3`, `>200 ms → 2` — with the sample supply defect described in
**M1**. It is open-loop in the control sense: it maps an *environmental*
measurement to a limit, and never observes whether the limit it chose produced
a better or worse outcome.

Three structural problems, none fixable by moving the thresholds:

1. **It cannot see load** (M1): probes are suppressed while busy.
2. **The bands are absolute constants.** A 250 ms satellite link that is
   perfectly happy at 4 concurrent reads is pinned to 2; a 40 ms link that is
   badly congested is given 4.
3. **Its only closed-loop signal is failure.** `onChannelOpenError`
   (`:84-90`) reacts to `MaxSessions` rejection — i.e. it learns only from
   damage already done, and learns nothing from the far more common case of
   the link merely being slower under concurrency.

Meanwhile the app already collects the right signal and throws it away for
this purpose. `CommandTelemetry.record` receives a `CommandSample` per command
with `lane`, `duration`, `bytes`, `wireBytes`, `compressed` and `success`
(`ssh_command_executor.dart:815-825`, `:929-940`) — measured **under exactly
the concurrency being controlled**.

**Proposal.** A gradient limiter over per-command latency, the standard shape
from TCP Vegas (and Netflix's `concurrency-limits`):

* Track `minRtt` — the best observed `read`-lane command duration, in a
  decaying window so a link that genuinely improves is not anchored forever.
* Track `currentRtt` — an EWMA of recent `read`-lane durations.
* Estimate queueing: `gradient = minRtt / currentRtt`, clamped to `(0, 1]`.
  `gradient` near 1 means no queue; falling means work is piling up.
* `newLimit = limit × gradient + allowance`, with `allowance ≈ sqrt(limit)` as
  the headroom that lets the limit probe upward.
* Smooth toward `newLimit`; clamp to `[1, maxReadCapHardLimit]`
  (`command_lanes.dart:152`); keep `onChannelOpenError` as a hard immediate
  floor drop, since `MaxSessions` is a cliff, not a gradient.

Why this is the right shape here rather than merely a fancier one:

* It measures the resource actually being contended — the host's willingness
  to serve concurrent commands, which is a mix of RTT, bandwidth, `sshd`
  limits and host load. No band table can encode that; `minRtt` per session
  discovers it.
* It is fed by samples that only exist *because* commands are running, which
  inverts M1's defect instead of patching it.
* It needs no new probe traffic, no new remote work, and no new plumbing —
  `CommandTelemetry` is already on the path.
* It degrades safely: with no samples it holds `noSampleCap`, exactly as
  today.

The RTT ping keeps its real job — liveness — and stops being asked to do a
second one it cannot do.

**Negative test that must be seen to fail:** feed a synthetic sample sequence
whose latency rises with concurrency and assert the limit falls; feed a
uniformly-slow-but-unqueued sequence (high `minRtt`, `currentRtt ≈ minRtt`) and
assert the limit does **not** fall. The second case is precisely what today's
band table gets wrong, so it must fail against the current implementation.

## Confirmed working (do not re-open)

Checked and found correct; recorded so a later pass does not spend time here.

* **Generation pinning.** Captured at enqueue (`ssh_command_executor.dart:520`),
  re-checked at run against both `generation` and `clientGeneration`
  (`:707-731`), held across retries. The `clientGeneration` distinction — a
  connect bumps the counter at its start but swaps the client at its end — is
  correctly handled at `:724-731`.
* **`_pending` handshake force-close.** A `Set`, not a slot, so overlapping
  handshakes are all closed by `disconnect()` (`ssh_client_manager.dart:181`,
  `:906-913`). The comment explaining why a single slot was wrong is accurate.
* **Host-key verifier serialization** (`:782-808`). The TOFU double-write and
  the stacked-prompt deadlock are both genuinely prevented.
* **Auth method selection** (`:839-853`). Not registering the password method
  for a key-only profile is correct and non-obvious — the naive `() => ''`
  burns `MaxAuthTries`.
* **`splitExitTrailer`** (`:684-694`). The end-anchored, digits-only trailer
  cannot false-match a stray `0x01` in real output, and a missing trailer
  correctly yields a failure code rather than 0.
* **Lane barrier semantics** (`command_lanes.dart:237-281`). Exclusive starts
  only from the queue head with nothing active and blocks everything behind
  it; reads and syncs are scanned past a full pool without blocking the
  queue. No starvation path found.
* **Scheduler watchdog** (`:283-330`). Slot released exactly once by whichever
  of body-settles / watchdog-fires comes first.
* **`ScopedCommandExecutor`** (`scoped_command_executor.dart`). Every member
  forwards; the overlay merges *under* caller `extraEnv` as documented.
* **`ShellEscaper`** (`shell_escaper.dart`). Single-quote wrapping with
  `'\''` is correct for POSIX, and the NUL rejection is right — a NUL cannot
  survive an argv.
* **Timeout cleanup** (`ssh_command_executor.dart:962-988`). The `timedOut`
  flag correctly handles a timeout that fires while the channel open is still
  pending, and TERM→KILL escalation is fire-and-forget so the caller is not
  held by a hung process.
* **`retries` allowlist** (`:613-655`). Timeouts, supersession, oversized
  output, auth and parse errors are all correctly non-retryable.

## Confirmation

This record is confirmed when a paired
`0024-PLAN-ssh-and-remote-repo-engine-debug-audit.md` exists that, for each
finding above:

1. names the exact files and lines it touches;
2. names the negative test, and records the observed failure text from running
   it against the unfixed tree — per `AGENTS.md`, a check that has only been
   seen to pass is not a check;
3. states the verification command and its expected output;
4. and, for M2 and M3, names the live-host configuration required, since
   neither can be confirmed offline.

`flutter analyze` and `flutter test` must be clean before any phase is staged.
Current baseline for comparison: **3,350 passing, 2 skipped, 48 failing**
(the 48 are the known pre-existing set, unchanged by this pass — no code was
modified).

## More Information

* Prior transport records:
  [0011](0011-MADR-ssh-transport-stability-hardening.md),
  [0012](0012-MADR-adopt-dartssh2-v3.md),
  [0013](0013-MADR-prefer-dartssh2-v3-over-dartssh3.md),
  [0014](0014-MADR-ssh-engine-next-wave-hardening.md),
  [0015](0015-MADR-ssh-engine-and-ui-unit-test-gaps.md),
  [0018](0018-MADR-transport-readiness-is-not-an-error.md),
  [0020](0020-MADR-fetch-pull-push-lag.md),
  [0022](0022-MADR-git-gh-glab-engine-debug-audit.md),
  [0023](0023-MADR-commit-and-push-perceived-freeze.md).
* `docs/ARCHITECTURE_PLAN.md` §0.1 remains the authoritative description of the
  SSH transport.
* Pinned library: `dartssh2` 3.3.0, read at
  `~/.pub-cache/hosted/pub.dev/dartssh2-3.3.0/`. Line citations above are
  against that exact version; a bump invalidates H3 and P2's round-trip
  arithmetic and both should be re-checked.
* Tree audited: `21721ef` on `master`, working tree clean.
