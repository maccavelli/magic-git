---
status: "executed"
date: 2026-08-20
executed: 2026-08-20
associated-madr: "0015-MADR-ssh-engine-and-ui-unit-test-gaps.md"
owner: [Maintainer]
target-milestone: Next work cycle (post-review)
---

# Implement Treat the 2026-08 SSH engine and UI/UX unit-test gap assessment as the coverage backlog

Associated MADR:
[0015-MADR-ssh-engine-and-ui-unit-test-gaps.md](./0015-MADR-ssh-engine-and-ui-unit-test-gaps.md)

This plan is the **single execution vehicle** for that decision's first
tranche **U1–U8**. It does not implement U9–U16, does not reopen 0011 / 0013
/ 0014 product choices, and does not restart
[TEST_COVERAGE_PLAN.md](./TEST_COVERAGE_PLAN.md). A second engineer
following only this file, against the tree at `e4c1c25` (2026-08-20), must
produce the same diff.

**One phase is already complete.** `e4c1c25` landed the forge-auth-pending
production fix and Phase 1's four tests in the same commit that added this
plan. Phase 1 is therefore a re-verification step, not new work; execution
starts at Phase 2. Every other phase is untouched.

## Outcome

**Executed 2026-08-20.** Phase 1 was already green on arrival; Phases 2–10
shipped in `39edbe0`. Full suite 3210 passed / 2 skipped, analyze and format
clean. Every HIGH id closed with a deletion check.

Three notes worth carrying forward:

* The `extends SSHClient` bet in Phase 3 paid off — dartssh2's constructor
  over a stub `SSHSocket` schedules no timers, so no `implements` fallback and
  no production extract was needed, and halt condition 1 never fired.
* The Phase 8 teardown hazard did not materialise: unmount plus a 1 s drain
  was enough, with no 3 s escalation and no dropped assertions.
* Phase 6's instruction to pump `MergeOptionsSheet` directly was impossible —
  the body is private. Driven through `showMergeOptionsSheet` instead, which
  is what the forge panels actually call. That mismatch became U19 in
  [the MADR](./0015-MADR-ssh-engine-and-ui-unit-test-gaps.md) and is now
  written into `AGENTS.md`.

## Goal

Prove, with tests that **fail if the production branch is deleted**, the
0014 wiring and the connect-time auth UI substitution that today exist
only as source or as leaf-level unit tests.

**Acceptance criteria**

1. **(a) Already met by `e4c1c25`** —
   `LocalCommandExecutor.execute(..., activityIdle: …)` completes when
   stdout or stderr keeps pulsing past the idle budget, and throws
   `SSHCommandTimeout` on silence; the ceiling still kills a pulsing
   command. **(b) Open** — the same four properties hold for
   `SSHCommandExecutor.execute`, driven through a fake session whose
   `stdout`/`stderr` pulse or stay silent.
2. `GitService.fetch` / `pull` / `push` (and the other
   `activityIdle: networkTimeout` call sites listed in Phase 2) pass
   `git.networkTimeout` into the executor; `status` passes `null`.
3. `SSHCommandExecutor.execute` on `ExecLane.sync` uses
   `SSHClientManager.syncClient`; non-sync lanes use `client`. When
   `syncClientDegraded` is true, sync shares the command client.
   `attachedClientCount` is 3 when all three slots are bound, 2 when
   sync is missing.
4. While a non-sync command is in `_run` and a sync command is not,
   `commandBusy == true` and `syncBusy == false` (and the reverse).
5. Sideload stdin is `addStream` then `flush` then `close`, in that
   order, never a single `write` of the whole buffer.
6. `decodeIdentities` round-trips a **passphrase-protected** OpenSSH
   PEM (skips if `ssh-keygen` is missing); the exported key parses
   without a passphrase (the three-client reuse story).
7. `RepoStatusView`, `FileView`, and `PaneError` show a `ProgressCircle`
   and **no** “not logged in” text when `forgeAuthPending` is true and
   the error looks like auth; after login has settled, the dump is
   shown. Tests must not leave `ProgressCircle` or Riverpod retry
   timers pending at teardown.
8. Dashboard latency row includes the labels `ssh clients` and
   `read cap` for a connected SSH session.
9. `flutter analyze` exit 0. Listed tests green. No `live-forge`. No
   sshd required. dartssh2 stays exact `3.3.0`. Read cap stays 4.

## Scope

**In scope (U1–U8)**

| ID | Work | State |
|---|---|---|
| U1a | Activity deadline through `LocalCommandExecutor.execute` | **done** in `e4c1c25`; Phase 1 re-verifies only |
| U1b | Activity deadline through `SSHCommandExecutor.execute` | open (needs the Phase 3 fake) |
| U2 | Sync-lane client routing + topology getters (`attachedClientCount`, `syncClientDegraded`) | open |
| U3 | `commandBusy` / `syncBusy` split while a command is in `_run` | open |
| U4 | `GitService` records `activityIdle` on network ops, not on status | open |
| U5 | Widget: pending auth → spinner, settled auth → dump (`PaneError` + both panes) | settled half done; **pending half open** |
| U6 | Dashboard `ssh clients` / `read cap` | open |
| U7 | Sideload stdin `addStream` + `flush` + `close` | open |
| U8 | Encrypted PEM `decodeIdentities` | open |

**Shared test infrastructure (Phase 3)** — `test/helpers/fake_ssh_client.dart`
and `SSHClientManager.bindTestClients`, used by U1b, U2, U3, U7. This is
the plan's **only** production change.

**Out of scope** (do not implement, even if adjacent)

* U9 live sshd `attachedClientCount == 3` / reads-during-sync
* U10 `SO_KEEPALIVE` `setRawOption` throw path
* U11 live sync/stream redial
* U12 `ActivityCommandExecutor` decorator
* U13 history / connection-form / forge-sheet smoke
* U14 in-session lost popup
* U15 settings stall-budget copy
* U16 env-cache key miss on username / port
* Per-atom chrome widgets, goldens, `HostKeyPrompt` equality
* dartssh3, read-cap raise, SFTP, `keepAliveInterval`
* New transport architecture (test seams only, as the MADR allows)

## Prerequisites

* Flutter SDK per `pubspec.yaml`. Commands: `flutter pub get`,
  `flutter analyze`, `flutter test` (`AGENTS.md`).
* New Dart must be analyzer-clean on the first pass (strict-casts,
  `unawaited_futures`, `prefer_final_locals`, `prefer_const_constructors`).
* `lib/core/providers/app_providers.dart` is classified as binary.
  Search/edit checks of that file **must** use `rg -a`.
* Do not commit unless the user asks. If they ask for phase commits:
  after that phase's analyze + listed tests, `git add` only that phase's
  files and `git commit --no-edit`. Never `-m` / `-F` / a heredoc.
* Never run `flutter test --run-skipped -t live-forge`.
* Halt rule: if a Phase 0 fact disagrees with this plan, **stop and
  update this plan**. Do not improvise.

## Phase 0 — Confirm facts (no commit)

Read, do not edit:

* `lib/core/exec/local_command_executor.dart` — `ActivityDeadline` at
  the `deadline` local (~197); `deadline?.pulse()` on stdout and stderr
  chunks (~272, ~284).
* `lib/core/ssh/ssh_command_executor.dart` — `_run` client pick
  (~676–678), `_activeSync` / `_activeNonSync` (~691–696),
  `ActivityDeadline` (~781), `deadline?.pulse()` (~818, ~847),
  `addStream` + `flush` (~793–795), `registerBusyProbes` in the
  constructor (~314), `commandBusy` / `syncBusy` (~303–305),
  `uploadBytes` → `_run` with `Uint8List` stdin (~401).
* `lib/core/ssh/ssh_client_manager.dart` — getters `client`,
  `streamClient`, `syncClient`, `syncClientDegraded`,
  `attachedClientCount` (~269–290); `decodeIdentities` (~716).
* `lib/core/git/git_service.dart` — `defaultNetworkTimeout` 3 min,
  `defaultNetworkCeiling` 30 min; `activityIdle: networkTimeout` at
  `deleteRemoteBranch`, `fetch`, `pull`, `push`, tag push,
  `deleteRemoteTag`, `lsRemoteTags`. `_snapshot` / `status` do not
  pass `activityIdle`.
* `lib/features/repository/repo_status_view.dart` and `file_view.dart`
  — `forgeAuthPending && looksLikeAuthFailure` → `ProgressCircle`.
* `lib/features/forge/forge_widgets.dart` — `PaneError` same branch.
* `lib/features/dashboard/dashboard_sheet.dart` — `_latencySection`
  labels `'ssh clients'`, `'read cap'`, `'channel opens'` (~353–391).
* `test/local_command_executor_test.dart` ~215–270 — the four
  `activityIdle:` cases Phase 1 specifies **already exist**. Confirm,
  do not re-add.
* dartssh2 3.3.0 in `~/.pub-cache/hosted/pub.dev/dartssh2-3.3.0/lib/src/`:
  - `socket/ssh_socket.dart` — `SSHSocket` is abstract with five members
    (`stream`, `sink`, `done`, `close()`, `destroy()`; `flush()` has a
    default body).
  - `ssh_client.dart` — `SSHClient`'s constructor takes an `SSHSocket`
    positionally and only builds an `SSHTransport`; `SSHTransport`'s
    constructor calls `_initSocket()` (one `stream.listen`) and
    `_startHandshake()` (writes the version banner to `socket.sink`).
    **No timers** are scheduled unless `handshakeTimeout` / `authTimeout`
    are non-null, and `_keepAlive` is `late final` so it is never
    initialised on a client that never becomes ready.
  - `ssh_session.dart` — `SSHSession`'s constructor requires an
    `SSHChannel`, so a session fake must `implements SSHSession`.
* Existing tests named in the MADR “already true” section — do not
  duplicate them.

**Halt if:** `activityIdle` is no longer threaded through
`CommandExecutor.execute`, or the three SSH client getters have been
removed. Update the MADR; do not invent a replacement transport.

---

## Phase 1 — U1a LocalCommandExecutor activity deadline (DONE — verify only, no commit)

**Landed in `e4c1c25`.** All four tests below are already in
`test/local_command_executor_test.dart` (~215–270) under these exact
names. Do **not** re-add them; run the file, confirm green, move to
Phase 2. The specification is retained so the acceptance criterion has a
definition and so a future revert is detectable.

**Files**

* `test/local_command_executor_test.dart` (already edited)

Do **not** change `ActivityDeadline` itself (already unit-tested). Do
**not** add an SSH fake here — that is Phase 3, and the SSH half of the
activity deadline is Phase 3b (U1b).

**Tests** (real `sh` in the existing `tempDir`, same style as the file's
current `pwd` / timeout tests)

1. `'activityIdle: stderr pulses past the idle budget still complete'`
   - `gitArgs`: `['sh', '-c', 'i=0; while [ $i -lt 8 ]; do echo p >&2; i=$((i+1)); sleep 0.05; done; echo ok']`
   - `activityIdle: Duration(milliseconds: 120)`, `timeout: Duration(seconds: 2)`
   - Expect `isSuccess` and stdout containing `ok`.
2. `'activityIdle: stdout pulses past the idle budget still complete'`
   - Same loop but `echo p` to stdout (not `>&2`).
3. `'activityIdle: silence throws SSHCommandTimeout'`
   - `['sh', '-c', 'sleep 1; echo ok']`
   - `activityIdle: Duration(milliseconds: 80)`, `timeout: Duration(seconds: 2)`
   - Expect `throwsA(isA<SSHCommandTimeout>())`.
4. `'activityIdle: ceiling still kills a pulsing command'`
   - Pulse every 20 ms, `activityIdle: Duration(seconds: 5)`,
     `timeout: Duration(milliseconds: 150)`
   - Expect `SSHCommandTimeout` (ceiling is the `timeout` argument).

**Verify:** `flutter test test/local_command_executor_test.dart` — green
with no diff. If any case is missing, the tree is not at `e4c1c25`;
re-read Phase 0 and treat this phase as live work.

---

## Phase 2 — U4 GitService `activityIdle` recording (commit)

**Files**

* **Edit** `test/mutations_test.dart`

**Change the fake, not GitService.** `_FakeExecutor.execute` already
accepts `activityIdle` and ignores it. Add:

```dart
final List<Duration?> activityIdles = [];
```

and `activityIdles.add(activityIdle);` next to `calls.add(gitArgs);`.

**Tests** (same `GitService(exec)` setup)

1. In the existing `'fetch / pull / push'` test, after the argv
   expects, assert:
   - the `fetch` call's `activityIdle` equals `git.networkTimeout`
     (default `GitService.defaultNetworkTimeout`)
   - each subsequent `pull` / `push` **git** call (not the
     `upstreamProbe` / `get-url` probes) equals `git.networkTimeout`
   - Map by `calls[i].contains('fetch'|'pull'|'push')`, not by index
     magic that breaks when a probe is inserted.
2. New `'network ops pass activityIdle; status does not'`:
   - Call, against the fake, at least:
     `fetch`, `pull`, `push`, `deleteRemoteBranch`, `deleteRemoteTag`,
     `lsRemoteTags`, and `status` (status may throw on empty snapshot
     stdout — if so, catch and still record the execute).
   - Every call whose argv contains `fetch`, `push`, `pull`, or
     `ls-remote` has `activityIdle == git.networkTimeout`.
   - The `status` snapshot `sh -c` (or `git status`) has
     `activityIdle == null`.
3. New `'custom networkTimeout reaches fetch'`:
   - `GitService(exec, networkTimeout: Duration(seconds: 17))`
   - `await git.fetch('/repo')`
   - the fetch call's `activityIdle` is `Duration(seconds: 17)`.

**Verify:** `flutter analyze`;
`flutter test test/mutations_test.dart`.

---

## Phase 3 — Fake SSH client + `bindTestClients` (commit)

**Files**

* **Create** `test/helpers/fake_ssh_client.dart`
* **Edit** `lib/core/ssh/ssh_client_manager.dart`

This phase is infrastructure. U2/U3/U7 will not compile without it.

### 3a. `SSHClientManager.bindTestClients`

Add, next to the existing `@visibleForTesting` `decodeIdentities` /
`streamRedialDelay`:

```dart
/// Test-only: install already-authenticated client slots without a
/// handshake. Stops and clears any live health monitors and redial
/// timers so a previously connected manager leaves nothing pending;
/// starts none of its own (no `ping` loop against a fake).
@visibleForTesting
void bindTestClients({
  SSHClient? command,
  SSHClient? stream,
  SSHClient? sync,
}) {
  _generation++;
  _health?.stop();
  _health = null;
  _streamHealth?.stop();
  _streamHealth = null;
  _syncHealth?.stop();
  _syncHealth = null;
  _redialTimer?.cancel();
  _redialTimer = null;
  _syncRedialTimer?.cancel();
  _syncRedialTimer = null;
  _client = command;
  _streamClient = stream;
  _syncClient = sync;
  _clientGeneration = command == null ? -1 : _generation;
}
```

Every field named here exists with that exact name
(`ssh_client_manager.dart` ~151–213). Do **not** start a
`ConnectionHealthMonitor`; production `connect()` is unchanged.

Generation pinning still holds: `_run` compares
`_clientManager.clientGeneration` against the `gen` its caller captured,
and a test that binds before it executes captures the post-bind
generation.

### 3b. `FakeSshClient` / `FakeSshSession`

In `test/helpers/fake_ssh_client.dart`:

**`FakeSshClient` `extends SSHClient`, it does not implement it.**
`implements SSHClient` would require ~45 public members — 22 final
fields (`socket`, `username`, `algorithms`, `ident`,
`keepAliveInterval`, and the whole handler-callback set), 6 getters
(`done`, `isClosed`, `authenticated`, `remoteVersion`, `strictKex`,
`serverSigAlgs`), and 17 methods including `httpClient`, `handlePacket`
and the `sessionId` setter. Extending inherits all of them:

```dart
/// A socket that accepts the handshake bytes dartssh2 writes on
/// construction and never answers. `done` never completes, so the
/// transport neither closes nor errors — the client just sits
/// un-negotiated while the overridden members below do the work.
class _NullSocket implements SSHSocket {
  final _incoming = StreamController<Uint8List>();
  final _outgoing = StreamController<List<int>>();
  final _done = Completer<void>();

  @override
  Stream<Uint8List> get stream => _incoming.stream;
  @override
  StreamSink<List<int>> get sink => _outgoing.sink;
  @override
  Future<void> get done => _done.future;
  @override
  Future<void> close() async => destroy();
  @override
  void destroy() {
    if (!_done.isCompleted) _done.complete();
  }
  @override
  Future<void> flush() async {}
}

class FakeSshClient extends SSHClient {
  FakeSshClient({this.hangExecute = false})
    : super(_NullSocket(), username: 'test', keepAliveInterval: null);
  ...
}
```

`keepAliveInterval: null` matters — the parameter defaults to 10 s, and
this project's production `connect()` also passes `null` (0013 / 0014).

Override on `FakeSshClient`:

* `execute(String command, {pty, x11, environment})` — record
  `command` into `List<String> executeCommands`, then return a new
  `FakeSshSession` (exposed as `List<FakeSshSession> sessions`). When
  `hangExecute` is true, return a stored `Completer<SSHSession>.future`
  instead, completed later by `completeExecute()`.
* `ping()`, `close()`, `flush()` — complete immediately; `close()`
  flips `isClosed` and destroys the socket.
* `done` — a `Completer<void>` the test can complete to simulate a
  transport death; `isClosed` — false until `close()`.

Everything else stays inherited. Nothing else is called on a client by
`SSHCommandExecutor` (`rg 'client\.' lib/core/ssh/ssh_command_executor.dart`
finds only `execute`).

**`FakeSshSession` `implements SSHSession`** — its production constructor
requires an `SSHChannel`, so extending is not available. The full public
surface is 13 members:

* `stdin` — a recording `StreamSink<Uint8List>` that appends to
  `List<String> stdinOps`: `'addStream'`, `'add'`, `'close'`.
  `addStream` must be distinguishable from `add`, which is the whole
  point of U7.
* `flush()` — appends `'flush'`, completes. (Production calls
  `session.flush()`, not `stdin.flush()`; both land in the same list.)
* `stdout` / `stderr` — `Stream<Uint8List>`; default to controllers
  that close immediately, or take injected ones (U1b pulses through
  these).
* `waitForExit({timeout})` — completes with `0`, or with an injected
  `Completer<int?>`. The executor drains both streams first and then
  awaits this, so a session whose streams never close never settles.
* `close()` / `kill(SSHSignal)` — complete any pending exit; these are
  the timeout-path cleanup.
* `write(Uint8List)` — appends `'write'` (so a regression to the old
  buffered path is *recorded*, not silently ignored).
* `exitCode`, `exitSignal`, `done`, `channel`, `resizeTerminal` — not
  read by the executor; `channel` throws `UnimplementedError`, the rest
  return null / no-op.

If dartssh2 grows a member in a future 3.3.x (this plan pins 3.3.0),
add the stub; do **not** bump dartssh2.

**Test in this phase** (so the helper is not dead code):

* `test/ssh_command_executor_test.dart` — one smoke:
  `'bindTestClients makes execute see an established connection'`
  - Bind a `FakeSshClient` as `command`
  - `execute(repoPath: '/r', gitArgs: ['true'])` returns success
    (empty session stdout, `waitForExit` 0)
  - Does not throw `'SSH connection not established.'`

**Verify:** `flutter analyze`;
`flutter test test/ssh_command_executor_test.dart`.

---

## Phase 3b — U1b activity deadline through `SSHCommandExecutor` (commit)

**Files**

* **Edit** `test/ssh_command_executor_test.dart`

MADR U1 asks for the deadline proven through *both* executors. The local
half shipped in `e4c1c25` (Phase 1); this is the SSH half, and it is the
one 0014 T2 was written for. It sits here because it is the first phase
the Phase 3 fake makes possible.

The production pulses are inside the drain — `deadline?.pulse()` at
`ssh_command_executor.dart` ~818 (stdout chunks) and ~847 (stderr
chunks) — so they only fire on bytes arriving from the session.

**Tests**

1. `'activityIdle: a session pulsing stderr past the idle budget completes'`
   - `FakeSshSession` with an injected `stderr` controller; a periodic
     emit every 40 ms for ~8 ticks, then close both streams and exit 0
   - `execute(..., activityIdle: Duration(milliseconds: 120),
     timeout: Duration(seconds: 2))`
   - Expect `isSuccess`
   - **Deletion check:** removing the `deadline?.pulse()` on the stderr
     map (~847) makes this throw
2. `'activityIdle: a session pulsing stdout past the idle budget completes'`
   - Same through `stdout` (guards the ~818 pulse)
3. `'activityIdle: a silent session throws SSHCommandTimeout'`
   - Streams open and quiet, no exit
   - `activityIdle: Duration(milliseconds: 80)`,
     `timeout: Duration(seconds: 2)`
   - Expect `throwsA(isA<SSHCommandTimeout>())`
4. `'activityIdle: the ceiling still kills a pulsing session'`
   - Pulse every 20 ms forever, `activityIdle: Duration(seconds: 5)`,
     `timeout: Duration(milliseconds: 150)`
   - Expect `SSHCommandTimeout`

Close the injected controllers in a `tearDown` / `addTearDown` so a
timed-out test leaves no periodic timer behind.

**Verify:** `flutter analyze`;
`flutter test test/ssh_command_executor_test.dart`.

---

## Phase 4 — U2 routing and topology (commit)

**Files**

* **Edit** `test/ssh_command_executor_test.dart`
* Rename the group
  `'SSHClientManager generation + dual-client surface'`
  → `'SSHClientManager generation + client slots'`
  (MADR LOW; do it here so the name matches triple-client).

**`executeCommands` holds formatted shell strings, not argv.** `_runBody`
passes `CommandFormatter.format(...)` output to `client.execute` — a
`cd '<repo>' && … <args>` string. So assert with a substring search, not
list membership:

```dart
bool ran(FakeSshClient c, String marker) =>
    c.executeCommands.any((cmd) => cmd.contains(marker));
```

Use markers that cannot collide with the `cd`/env prefix — `'zz-read'`,
`'zz-sync'`, `'zz-mut'`, not `'cmd'`/`'syn'`/`'mut'`.

**Tests**

1. `'ExecLane.sync uses syncClient; other lanes use command client'`
   - Two `FakeSshClient` instances (`cmd`, `sync`), distinct
     identities.
   - `bindTestClients(command: cmd, sync: sync)`
   - `execute(..., gitArgs: ['zz-read'], lane: ExecLane.read)`
   - `execute(..., gitArgs: ['zz-sync'], lane: ExecLane.sync)`
   - `execute(..., gitArgs: ['zz-mut'], lane: ExecLane.exclusive)`
   - Expect `ran(cmd, 'zz-read')` and `ran(cmd, 'zz-mut')` true,
     `ran(cmd, 'zz-sync')` false.
   - Expect `ran(sync, 'zz-sync')` true and the other two false.
   - **Deletion check:** removing the `lane == ExecLane.sync`
     ternary in `_run` (~676) and always using `client` fails this
     test.
2. `'degraded sync shares the command client'`
   - `bindTestClients(command: cmd, stream: stream, sync: null)`
   - Expect `manager.syncClientDegraded` is true (the getter is
     `_client != null && _syncClient == null`, ~284)
   - Expect `manager.attachedClientCount == 2`
   - `execute(..., gitArgs: ['zz-sync'], lane: ExecLane.sync)` records
     on `cmd` — `syncClient` falls back to `_client` (~281), so this
     also proves the fallback is the *command* client and not a
     silently-null one.
3. `'attachedClientCount is 3 when all slots are bound'`
   - Bind three distinct fakes; expect `3`.
   - Bind none; expect `0` (already true for a fresh manager;
     keep as a sanity next to the existing disconnected-getters
     test).

**Verify:** `flutter analyze`;
`flutter test test/ssh_command_executor_test.dart`.

---

## Phase 5 — U3 busy-pause split (commit)

**Files**

* **Edit** `test/ssh_command_executor_test.dart`
  (or a new `test/ssh_busy_split_test.dart` if the executor file
  is getting long — prefer the existing file unless it exceeds
  ~500 lines after Phase 4).

**Tests**

1. `'commandBusy is true during a hung read; syncBusy stays false'`
   - `FakeSshClient(hangExecute: true)` as command; a second
     non-hanging fake as sync (unused).
   - `bindTestClients(command: hung, sync: idle)`
   - `final pending = executor.execute(repoPath: '/r', gitArgs: ['sleep'], lane: ExecLane.read)`
   - `await Future<void>.delayed(Duration.zero)` (let `_run` pass
     the increment)
   - Expect `executor.commandBusy` is true, `executor.syncBusy` is
     false, `executor.transportBusy` is true
   - Unblock: `hung.completeExecute()` (add this API to the fake:
     complete the hung `execute` Completer with a session whose
     streams close) then `await pending`
   - After settle: both busy flags false
2. `'syncBusy is true during a hung sync; commandBusy stays false'`
   - Mirror, `lane: ExecLane.sync`, hung client in the **sync**
     slot.

Do **not** start real `ConnectionHealthMonitor` timers here. The
MADR's “wire the two probes” is satisfied by asserting the probe
*sources* (`commandBusy` / `syncBusy`) that
`registerBusyProbes` already installs. Monitor skip-when-busy is
already in `connection_health_monitor_test.dart`.

**Verify:** `flutter analyze`;
`flutter test test/ssh_command_executor_test.dart`
(and `test/ssh_busy_split_test.dart` if created);
`flutter test test/connection_health_monitor_test.dart`.

---

## Phase 6 — U7 sideload stdin order (commit)

**Files**

* **Edit** `test/ssh_command_executor_test.dart`
* Production `uploadBytes` / `_runBody` stays as-is unless the
  fake cannot see `addStream` — then extract the three calls into
  a `@visibleForTesting` helper and call it from `_runBody`. Prefer
  **no production extract** if `FakeSshSession.stdinOps` already
  records the order.

`uploadBytes` (~401) runs `sh -c 'cat > <escaped>'` on
**`ExecLane.isolated`** through `runWithRetries`, and throws unless the
result is exit 0 — so bind the fake in the **command** slot (isolated is
not the sync lane) and make sure `waitForExit()` yields `0`, or the
upload throws before the assertion is reached.

**Test**

`'uploadBytes feeds stdin via addStream, flush, then close'`

* Bind a `FakeSshClient` as command
* `await executor.uploadBytes('/tmp/x', Uint8List.fromList([1, 2, 3]))`
* On the session created for that execute:
  - `stdinOps` is `['addStream', 'flush', 'close']` (allow
    `['addStream', 'close']` only if `flush` is a no-op on an empty
    controller — **fail the test if `stdinOps` contains `'write'` or a
    bare `'add'` without `'addStream'`**, which is the 0014 T7
    regression)
  - `executeCommands.single` contains `cat >` and the escaped path

**Deletion check:** changing `_runBody` back to `s.write(stdin);
await s.stdin.close();` must fail this test — which is why
`FakeSshSession.write` records `'write'` rather than throwing.

**Verify:** `flutter analyze`;
`flutter test test/ssh_command_executor_test.dart`.

---

## Phase 7 — U8 encrypted PEM (commit)

**Files**

* **Edit** `test/ssh_key_decode_isolate_test.dart`

Follow the existing unencrypted test's skip:
`if (!File('/usr/bin/ssh-keygen').existsSync()) return;`

**Tests**

1. `'decodeIdentities round-trips a passphrase-protected OpenSSH ed25519 PEM'`
   - `ssh-keygen -q -t ed25519 -N 'test-pass' -C '' -f $path`
   - `decodeIdentities(pem, 'test-pass')` is not empty
   - `SSHKeyPair.fromPem(keys.first.toPem())` **without** a
     passphrase succeeds (unencrypted export — the three-client
     reuse)
   - Public keys match, same assertion as the unencrypted test
2. `'decodeIdentities rejects the wrong passphrase'`
   - Same PEM, passphrase `'nope'`
   - Expect a throw (`SSHKeyDecryptError` or whatever dartssh2
     3.3.0 actually throws — pin the type after one local run;
     do not catch `Object` and pass)

Do **not** assert Isolate.run call counts (not observable without
a hook). The unencrypted export is the reuse proof.

**Verify:** `flutter analyze`;
`flutter test test/ssh_key_decode_isolate_test.dart`.

---

## Phase 8 — U5 pending-auth spinner widgets (commit)

**Files**

* **Edit** `test/forge_list_error_test.dart`
* **Edit** `test/repo_status_view_test.dart`
* **Edit** `test/file_view_test.dart`

**Teardown protocol** (mandatory on every spinner test; this is
why the earlier attempt failed)

After the expects, before the test function returns:

```dart
container.dispose();
await tester.pumpWidget(const SizedBox.shrink());
await tester.pump(const Duration(seconds: 1));
```

If `_pump` already `addTearDown(container.dispose)`, dispose
idempotently (Riverpod `ProviderContainer.dispose` is safe to
call once; skip a second dispose by nulling the local / using a
flag). The `SizedBox.shrink()` unmounts `ProgressCircle`. The
1 s pump drains Riverpod retry timers (200 ms, 400 ms, …).

### 8a. `PaneError`

In `forge_list_error_test.dart`, using the existing `_StubConnection`
pattern from `repo_status_view_test.dart` (copy a 4-line stub;
do not import from that test file):

1. `'PaneError shows a spinner for an auth failure while forge login is pending'`
   - Override `connectionProvider` with
     `ConnectionState(phase: connected, forgeAuthPending: true)`
   - `PaneError(Exception('not logged in to github.com'))`
   - Expect `find.byType(ProgressCircle)` finds widgets
   - Expect `find.textContaining('not logged in')` finds nothing
   - Then teardown protocol
2. `'PaneError shows the dump once forge login has settled'`
   - Default `forgeAuthPending: false`
   - Expect the dump, no spinner
   - Existing `ForgeListError` tests stay

### 8b. Repo status pane

Extend `_pump` with `Object? statusError` (already present from
the settled-auth test) **and** `bool forgeAuthPending = false`
passed into the `_StubConnection` `ConnectionState`.

1. Reuse the settled test that already shows the dump.
2. New `'a not-logged-in status error shows a spinner while forge login is pending'`
   - `statusError:` the same `GitException` / stderr `'glab: not logged in'`
   - `forgeAuthPending: true`
   - After first `pump` (not `pumpAndSettle` — ticker), expect
     spinner and no dump
   - Teardown protocol instead of `pumpAndSettle`

If `_pump` always `pumpAndSettle`s, add `bool settle = true` and
pass `settle: false` for this test only.

### 8c. File view pane

Standalone `pumpWidget` (do not fight `_pump`'s
`repoStructureProvider` override order):

* Override `repoStructureProvider(_repo)` to throw the same
  `GitException`
* Override `connectionProvider` with `forgeAuthPending: true`
* Override `repoStatusOverlayProvider` to `_overlay` (already in
  the file)
* `SharedPreferences.setMockInitialValues(const {})`
* Expect spinner, no dump, teardown protocol

Settled dump test already in this file — keep it.

**Verify:** `flutter analyze`;
`flutter test test/forge_list_error_test.dart test/repo_status_view_test.dart test/file_view_test.dart`.

**Halt if:** teardown still reports `!timersPending` after the
protocol. Do **not** skip the test. Extend the pump to 3 s or
dispose the container **before** unmounting, then re-run. Do not
leave the spinner assertion out.

---

## Phase 9 — U6 Dashboard transport stats (commit)

**Files**

* **Edit** `test/dashboard_sheet_test.dart`

Dashboard reads `ref.read(sshClientManagerProvider)` and
`ref.read(executorProvider)` inside `_latencySection` — not
watched. Override both.

`SSHClientManager` declares no constructor, so the default no-arg one
applies and this subclass compiles as written:

```dart
class _TripleManager extends SSHClientManager {
  @override
  int get attachedClientCount => 3;
}
```

Use a real `SSHCommandExecutor(_TripleManager())` (one positional
argument) for `executorProvider`. Its `adaptiveReadCap` then reports
`AdaptiveReadConcurrency.noSampleCap`, which is **3** — the *ceiling*
is 4 and stays 4 (acceptance criterion 9). Assert the label, not the
number, so a future band change does not break this test. Overriding
`adaptiveReadCap` instead is possible (a plain instance getter,
`ssh_command_executor.dart` ~339) but unnecessary.

**Test** (extend `'renders the session sections from live providers'`
or add a sibling)

* Expect `find.text('ssh clients')`
* Expect `find.text('read cap')`
* Expect `find.text('triple')` when `attachedClientCount` is 3
* Expect `find.text('channel opens')` (the label; the count may
  be `0`)

Keep discrete pumps (uptime ticker). Close via X as the existing
test does so the ticker is disposed.

**Verify:** `flutter analyze`;
`flutter test test/dashboard_sheet_test.dart`.

---

## Phase 10 — Full gate (no extra commit if clean)

```sh
flutter analyze
flutter test test/local_command_executor_test.dart \
  test/mutations_test.dart \
  test/ssh_command_executor_test.dart \
  test/ssh_key_decode_isolate_test.dart \
  test/forge_list_error_test.dart \
  test/repo_status_view_test.dart \
  test/file_view_test.dart \
  test/dashboard_sheet_test.dart \
  test/connection_health_monitor_test.dart \
  test/activity_deadline_test.dart \
  test/connection_race_test.dart \
  test/ssh_transport_hardening_test.dart \
  test/adaptive_read_concurrency_test.dart
```

If `test/ssh_busy_split_test.dart` was created, include it.

Then `flutter test` (full unit suite, no `--run-skipped`).

Never `live-forge`. Do not require `/usr/sbin/sshd`.

If analyze or a listed test fails, fix in the phase that
introduced the break.

## Verification

| # | Check |
|---|---|
| 1 | `flutter analyze` exit 0 |
| 2 | Phase 10 listed tests + full `flutter test` exit 0 |
| 3 | U1a (already green): pulsing local `sh` survives `activityIdle`; silence throws `SSHCommandTimeout` |
| 3b | U1b: a session pulsing stdout **or** stderr survives `activityIdle` through `SSHCommandExecutor.execute`; a silent session throws; the ceiling still kills a pulser |
| 4 | U4: fetch `activityIdle == networkTimeout`; status is `null` |
| 5 | U2: sync lane records on the sync fake; degraded sync records on the command fake; count 3 / 2 |
| 6 | U3: hung read ⇒ `commandBusy && !syncBusy` |
| 7 | U7: stdin ops are addStream → flush → close |
| 8 | U8: passphrase PEM decodes; `toPem()` parses without passphrase (or skip without ssh-keygen) |
| 9 | U5: pending ⇒ `ProgressCircle`, no dump; settled ⇒ dump; no pending timers |
| 10 | U6: Dashboard shows `ssh clients` and `read cap` |
| 11 | No `keepAliveInterval:` other than `null` (the `FakeSshClient` super-call included); dartssh2 exact `3.3.0`; `AdaptiveReadConcurrency.ceiling` still 4 |
| 12 | `bindTestClients` is the only production change; it is `@visibleForTesting`, starts no monitor, and leaves no timer |

A HIGH ID is **not** closed by creating a file with a similar name.
Each test above must fail if the cited production branch is deleted.

## Rollout and Rollback

**Rollout.** Tests only, plus the `bindTestClients` test seam (dead
in production). No settings schema, no unsigned `.app` unless the
user asks after the suite is green.

**Rollback.** Revert phase commits in reverse order, down to but not
including `e4c1c25` (Phase 1 and the production auth fix are not part of
this rollout). Phase 3's `bindTestClients` must revert with
U1b/U2/U3/U7 or those tests will not compile.

**Risks**

* `extends SSHClient` runs dartssh2's real constructor against
  `_NullSocket`. It writes a version banner and a KEXINIT into a
  `StreamController` nobody drains — harmless, but close the
  controllers in `tearDown` so the analyzer's `unawaited_futures` and
  the test binding both stay quiet.
* Widget teardown (`ProgressCircle` + Riverpod retry) is the
  only known flake mode; Phase 8 halt handles it.
* Encrypted PEM test skips on machines without `ssh-keygen`
  (same contract as the existing unencrypted test).

## Halt conditions (do not improvise)

1. `extends SSHClient` against `_NullSocket` throws, hangs, or leaves a
   pending timer at teardown (it should not — `SSHTransport`'s
   constructor schedules none) → fall back to
   `implements SSHClient` with the full ~45-member stub set, **not**
   to `dynamic`. Only if that is also impossible: extract
   `@visibleForTesting` `feedSessionStdin` for U7 and
   `@visibleForTesting SSHClient? clientFor(ExecLane)` **called by
   `_run`** for U2, and update this plan with the extract. Do not skip
   U2.
2. `bindTestClients` would start health monitors that ping the
   fake forever → do not start them (as specified).
3. Phase 8 teardown still fails `!timersPending` after a 3 s pump
   and dispose → report; do not delete the spinner assertion.
4. Any phase wants dartssh3, a read-cap raise, SFTP, or
   `keepAliveInterval` non-null → stop; that is a different MADR.
