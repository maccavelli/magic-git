---
status: "proposed"
date: 2026-08-20
verified: 2026-08-20
associated-madr: "0018-MADR-transport-readiness-is-not-an-error.md"
owner: [Maintainer]
target-milestone: This work cycle
---

# Implement: transport readiness is a state, not a failed command

Associated MADR:
[0018-MADR-transport-readiness-is-not-an-error.md](./0018-MADR-transport-readiness-is-not-an-error.md)

Stop `SSH connection not established.` from ever reaching a pane: reproduce
the cold-connect trigger, type the condition, render it as a loading state,
and correct the invalidate/flip ordering in the four inverted lifecycle
paths.

A second engineer following only this file, against the tree at `c755518`,
must produce the same diff.

## Goal

**Acceptance criteria**

1. A test reproduces the maintainer's symptom — a repo pane rendering the
   not-ready error — and fails on the tree as it stands today.
2. `SSHTransportNotReady` is thrown at both sites instead of a bare
   `Exception`, and `humanizeSshError` maps it.
3. The string `SSH connection not established.` exists in no user-facing
   path; a test asserts this rather than a reviewer eyeballing it.
4. `RepoStatusView`, `FileView` and `PaneError` render a `ProgressCircle`
   for a not-ready transport, never a red dump.
5. `connect()`, `disconnect()`, the backend switch and the provisioning path
   each publish their new `ConnectionState` **before** calling
   `_invalidateRepoState()`; a test fails if the order is restored.
6. Riverpod retry stays off — `provider_retry_policy_test.dart` passes
   unchanged, all five tests.
7. `flutter analyze` exit 0, `dart format` clean on touched files, full
   `flutter test` green. No `live-forge`.

## Scope

**In scope**

| # | Work |
|---|---|
| 1 | Instrumented reproduction of the cold-connect trigger — **done, see MADR** |
| 1b | `transportSettled` / `isTransportReady` on `ConnectionController` |
| 1c | `ReadinessGatedExecutor` decorator + its contract |
| 2 | `SSHTransportNotReady` + humanizer branch |
| 3 | Panes treat not-ready as loading |
| 4 | Flip-then-invalidate in the four inverted paths |
| 5 | Regression tests, including a no-developer-strings scan |

**Out of scope** (do not implement, even if adjacent)

* Making the executor wait *unconditionally*, poll, or retry for a client
  (MADR option B). The gate waits only while an attempt is in flight, and
  only up to `transportGrace`.
* Gating providers individually (MADR: ~30 members, one seam is better).
* Any build-time dependency from `activeExecutorProvider` or the decorator
  onto `connectionProvider` — that is the `CircularDependencyError` the
  chain was built to avoid.
* Re-enabling Riverpod provider retry (MADR option D).
* Any change to `openRepo()`'s ordering (~2515): it invalidates with a live
  client, which is wasteful, not incorrect. Note it, leave it.
* Reworking `_invalidateRepoState`'s *contents* — only its call ordering.
* The `.app` build. Phase 5 asks the maintainer to confirm on a real
  connect; that is a verification step, not implementation.

## Prerequisites

* Commands: `flutter analyze`, `flutter test`, `dart format`.
* `lib/core/providers/app_providers.dart` is classified as **binary** by
  search tools — use `rg -a`, and script the edits.
* Do not commit unless asked; if asked, one commit per phase,
  `git commit --no-edit`.
* **Halt rule:** if Phase 1 cannot reproduce the symptom, stop and report.
  Do not proceed to a fix for a trigger that has not been demonstrated.

## Phase 0 — Confirm facts (no commit)

Read, do not edit:

* `lib/core/ssh/ssh_command_executor.dart` — the two
  `throw Exception('SSH connection not established.')` sites (~680 in
  `_run`, ~1015 in `executeStream`), and the existing exception classes
  (`SSHCommandTimeout` ~61, `SSHCommandSuperseded` ~77) whose shape the new
  type copies: `implements Exception`, one `final String command`, a const
  constructor, a `toString()`.
* `lib/core/ssh/ssh_error_messages.dart` ~64 — `humanizeSshError`'s branch
  order; the new branch goes beside `SSHCommandSuperseded`, which is the
  nearest neighbour in meaning.
* `lib/core/utils/display_error.dart` — `displayError` and
  `looksLikeAuthFailure`.
* `lib/core/providers/app_providers.dart` — `_invalidateRepoState` ~1042 and
  its five call sites (~1281, ~1764, ~2134, ~2331, ~2515, ~2580);
  `repoScopedFetchFamilies` ~2670 (confirm `statusProvider` and
  `repoStructureProvider` are members).
* `lib/features/repository/repo_status_view.dart` ~1671,
  `lib/features/repository/file_view.dart` ~722,
  `lib/features/forge/forge_widgets.dart` ~183 — the `forgeAuthPending &&
  looksLikeAuthFailure` → `ProgressCircle` branch this plan extends.
* `test/connection_race_test.dart` — the existing connect/disconnect race
  harness (`_GatedManager`, `_GatedGh`), which Phase 1 extends rather than
  duplicates.

**Halt if:** the throw sites are already typed, or `_invalidateRepoState`
has been reordered — the tree is not at `c755518` and this plan needs
re-grounding.

---

## Phase 1 — Reproduce the trigger (commit)

**This phase decides whether the rest of the plan is correct.** The MADR
records an open question: reasoning from the shell's gate says a *cold*
connect cannot mount the panes before `connected`, yet the maintainer
observed exactly that. Find out which is true before writing a fix.

**Files**

* **Create** `test/transport_readiness_race_test.dart`

### 1a. Instrument the executor's view of the world

A recording executor that answers *when* a command was attempted relative to
the connection lifecycle:

```dart
class _WhenExecutor extends SSHCommandExecutor {
  _WhenExecutor(this._manager, this._phase) : super(_manager);
  final SSHClientManager _manager;
  final ConnectionPhase Function() _phase;

  /// One entry per attempted command: what ran, the phase the UI believed it
  /// was in, and whether a client was actually attached.
  final List<({List<String> argv, ConnectionPhase phase, bool clientAttached})>
      attempts = [];
  ...
}
```

Record on every `execute` / `executeStream`, then delegate or return a canned
result. The interesting row is any attempt with
`clientAttached == false` — and its `phase` names the trigger.

### 1b. Drive a cold connect with the panes mounted

Build a container the way the app does — **`appProviderContainer`**
(`test/helpers/app_scope.dart`), so retry is off exactly as in production —
then:

* override `sshClientManagerProvider` with a gated fake whose `connect()`
  does not complete until the test releases it, and whose `client` stays
  null until then (this is the cold-connect shape);
* override `executorProvider` with `_WhenExecutor`;
* pump `AppShell` (the real one — the gate under test is *its* gate);
* call `connect()`, pump frames while it is in flight, release the gate,
  pump again.

### 1c. Assert the symptom, then name it

1. `'a cold connect never runs a repo command before the client attaches'`
   - Expect `attempts.where((a) => !a.clientAttached)` to be **empty**.
   - **This is expected to FAIL on the current tree.** Its failure output —
     the argv and the phase of each offending attempt — is the answer to the
     MADR's open question. Record it verbatim in the commit message and in
     the MADR under "What is NOT yet confirmed".
2. `'a pane never renders the not-ready error'`
   - After the same sequence, assert
     `find.textContaining('not established')` finds nothing at every pumped
     frame (pump in a loop, checking between frames).

**Halt if:** both tests pass on the current tree. Then the trigger is
outside this harness — report the fact, and do not write Phases 2–4 against
a race that cannot be shown. Candidates to chase next, in order: a restored
saved workspace mounting a tab with a repoPath; `TabsController` container
reuse across a reconnect; the pop-out relay's `ProxyCommandExecutor`.

**Verify:** `flutter analyze`;
`flutter test test/transport_readiness_race_test.dart` — expect the
documented failure, and commit the test in its failing state only if the
repo convention allows; otherwise hold it uncommitted until Phase 4 makes it
pass, and say so in the phase commit.

---

## Phase 1b — The readiness signal (commit)

**Files**

* **Edit** `lib/core/providers/app_providers.dart`
* **Edit** `test/connection_race_test.dart`

`ConnectionController` already exposes a settle gate for forge logins
(`forgeAuthSettled` ~893, `isForgeAuthSettled` ~898). Add its transport
sibling, in the same shape and next to it:

```dart
/// Completes when the in-flight connect attempt settles — connected, failed,
/// or superseded. Already complete when no attempt is in flight, so awaiting
/// it on a disconnected session returns at once rather than hanging.
Future<void> get transportSettled => _transportGate.future;

/// True when a command can actually run right now.
///
/// Consults BOTH halves deliberately: `phase == connected` alone is not
/// enough (a connect publishes `connecting` while no client exists, and a
/// drop leaves `connected` standing for a frame), and a live client alone is
/// not enough (it may belong to a superseded attempt). A local session has no
/// transport, so the state is the whole answer there.
bool get isTransportReady => switch (state.backend) {
  ConnectionBackend.local => state.isConnected,
  ConnectionBackend.ssh =>
    state.isConnected && ref.read(sshClientManagerProvider).client != null,
};
```

`_transportGate` is a `Completer<void>` **initialised already-completed**
(nothing in flight at construction), replaced with a fresh one at the top of
every connect attempt, and completed in that attempt's `finally` — so it
settles on success, failure and supersession alike. Mirror `_forgeAuthGate`'s
lifecycle exactly; it is the proven shape.

**Tests** (in `connection_race_test.dart`, beside the existing gate tests)

1. `'transportSettled is already complete when nothing is in flight'` —
   awaiting it on a fresh controller returns without pumping.
2. `'transportSettled completes when a connect fails'` — gated manager,
   release the gate with an error, assert the future completes rather than
   hanging.
3. `'transportSettled completes when a connect is superseded'` — start two
   connects, assert the first attempt's gate still settles.
4. `'isTransportReady is false while connecting and true once connected'`.

**Halt if:** completing the gate in `finally` double-completes on any path —
guard with `isCompleted`, as `_forgeAuthGate` does.

**Verify:** `flutter analyze`;
`flutter test test/connection_race_test.dart`.

---

## Phase 1c — The gated executor (commit)

**Files**

* **Create** `lib/core/exec/readiness_gated_executor.dart`
* **Edit** `lib/core/providers/app_providers.dart` (compose it)
* **Create** `test/readiness_gated_executor_test.dart`

### 1c.1 The decorator

Same shape as `ActivityCommandExecutor` (`lib/core/exec/`): implements
`CommandExecutor`, forwards everything, adds one behaviour.

```dart
/// Refuses to issue a command the session cannot run, and — while a connect
/// is in flight — waits for it rather than failing a command that is about to
/// become possible. See MADR 0018's readiness contract.
class ReadinessGatedExecutor implements CommandExecutor {
  ReadinessGatedExecutor(
    this._inner, {
    required this.isReady,
    required this.settled,
    this.grace = defaultGrace,
  });

  /// How long a command may wait for an in-flight connect before giving up.
  /// Not a correctness mechanism: `_invalidateRepoState` refetches on every
  /// connect, so a command that gives up is re-run when the session settles.
  /// This only saves that extra round trip.
  static const Duration defaultGrace = Duration(seconds: 10);

  final CommandExecutor _inner;
  final bool Function() isReady;
  final Future<void> Function() settled;
  final Duration grace;
  ...
}
```

`isReady` and `settled` are **callbacks read at call time**, never providers
captured at build time — that is what keeps `activeExecutorProvider` off
`connectionProvider` and avoids the `CircularDependencyError` documented at
`app_providers.dart` ~207–215.

The guard, applied to `execute` and `executeStream` (and **not** to
`uploadBytes`, `configureEnvironment`, `resetEnvironment`,
`resolvedBinaryPath`, `setForgeTokenNeutralization` — see 1c.2):

```dart
Future<void> _awaitReady(List<String> gitArgs) async {
  if (isReady()) return;                      // fast path: no await, no timer
  final inFlight = settled();
  if (_alreadyComplete(inFlight)) {
    throw SSHTransportNotReady(gitArgs.join(' '));
  }
  await inFlight.timeout(grace, onTimeout: () {});
  if (!isReady()) throw SSHTransportNotReady(gitArgs.join(' '));
}
```

Two details that matter:

* **The fast path must not `await`.** `_awaitReady` is `async`, so calling it
  always costs a microtask; make the *caller* check `isReady()` first and skip
  the call entirely, or return a synchronously-completed path. Assert the cost
  in a test (1c.3 case 6) rather than trusting it.
* **"Nothing in flight" must be detectable without waiting.** A `Future` gives
  no synchronous "is it done" answer, so `ConnectionController` must expose
  `bool get isTransportSettled` beside the future — mirroring
  `isForgeAuthSettled` ~898 — and the decorator takes that as a third
  callback. Do **not** approximate it with a zero-duration timeout race.

### 1c.2 What is NOT gated

`uploadBytes` is used by the install/sideload path, which manages its own
session expectations; the env/probe methods are synchronous configuration, not
commands. Gating them would change connect-time setup, which runs *before*
readiness by design. Leave them forwarding untouched, and say so in the class
doc.

### 1c.3 Tests

`test/readiness_gated_executor_test.dart`, with a recording inner executor:

1. `'ready: forwards immediately'` — inner sees the command; no wait.
2. `'not ready, nothing in flight: throws at once and never forwards'` —
   inner sees nothing; `SSHTransportNotReady`; assert it did **not** wait
   (complete a `Stopwatch` under a few ms, or assert no timer via
   `fakeAsync`).
3. `'not ready, connect in flight: waits, then forwards once ready'` —
   settle the gate and flip `isReady`, assert the command runs.
4. `'not ready, connect in flight that fails: throws after the gate settles'`.
5. `'grace elapses: throws rather than waiting forever'` — use `fakeAsync`
   and advance past `grace`; assert no pending timers afterwards.
6. `'the ready path adds no timer and no extra microtask'` — under
   `fakeAsync`, run a ready command and assert zero pending timers; this is
   the hot-path cost assertion the MADR asks for.
7. `'executeStream is gated the same way'`.
8. `'uploadBytes and configureEnvironment are not gated'` — they forward
   even when not ready.

### 1c.4 Composition

In `gitServiceProvider`, wrap `activeExecutorProvider` **inside** the existing
`ActivityCommandExecutor` (readiness first, so a refused command never opens an
activity record):

```dart
final gated = ReadinessGatedExecutor(
  ref.watch(activeExecutorProvider),
  isReady: () => ref.read(connectionProvider.notifier).isTransportReady,
  settled: () => ref.read(connectionProvider.notifier).transportSettled,
  isSettled: () => ref.read(connectionProvider.notifier).isTransportSettled,
);
final activityExecutor = ActivityCommandExecutor(gated, ...);
```

Apply the same wrap to the **scoped** executor built lower in the same
provider (~314), so scoped-repo commands are gated identically.

**Halt if:** `flutter test` reports `CircularDependencyError` anywhere. That
means a callback was replaced by a `watch`; revert to the callback form.

**Verify:** `flutter analyze`;
`flutter test test/readiness_gated_executor_test.dart test/app_providers_test.dart test/connection_race_test.dart test/transport_readiness_race_test.dart` —
**Phase 1's reproduction must now pass**, since no command is issued
unattached.

---

## Phase 2 — Type the condition (commit)

**Files**

* **Edit** `lib/core/ssh/ssh_command_executor.dart`
* **Edit** `lib/core/ssh/ssh_error_messages.dart`
* **Edit** `test/ssh_error_messages_test.dart`

### 2a. The type

Beside `SSHCommandSuperseded` (~77), matching its shape exactly:

```dart
/// Thrown when a command is issued before a client is attached — during a
/// connect, or after a drop cleared it. Distinct from [SSHCommandSuperseded]
/// (a connection *changed*) and from any command failure: nothing ran, and
/// the caller is early rather than wrong. Typed so the UI can render it as
/// "still connecting" instead of a red error — see MADR 0018.
class SSHTransportNotReady implements Exception {
  final String command;
  const SSHTransportNotReady(this.command);

  @override
  String toString() => 'SSH transport is not ready yet: $command';
}
```

Throw it at both sites in place of the bare `Exception`, passing
`gitArgs.join(' ')` as the command — the same argument the neighbouring
throws use.

### 2b. The humanizer

In `humanizeSshError`, directly after the `SSHCommandSuperseded` branch:

```dart
if (error is SSHTransportNotReady) {
  return 'Still connecting to the host — this will refresh on its own.';
}
```

### 2c. Tests

In `test/ssh_error_messages_test.dart`:

1. `'a not-ready transport reads as still connecting, not as a failure'` —
   `humanizeSshError(const SSHTransportNotReady('git status'))` contains
   `'Still connecting'` and does **not** contain `'not established'`.
2. `'the not-ready error never leaks its developer text'` — assert the
   humanized string shares no words with `toString()`'s internals beyond
   incidental ones; concretely, `isNot(contains('SSH transport is not'))`.

**Deletion check:** revert one throw site to `Exception(...)` and confirm
test 1 in Phase 4's pane suite fails; restore.

**Verify:** `flutter analyze`;
`flutter test test/ssh_error_messages_test.dart test/ssh_command_executor_test.dart`.

---

## Phase 3 — Flip, then invalidate (commit)

**Files**

* **Edit** `lib/core/providers/app_providers.dart`
* **Create** `test/connection_invalidate_order_test.dart`

### 3a. The reordering

Four sites, one rule: **publish the new `ConnectionState`, then call
`_invalidateRepoState()`.** Once the state says "not connected", the shell
has unmounted the panes, so the refetch has no listener to fail in front of.

| site | today | after |
|---|---|---|
| `connect()` ~1281 | `_invalidateRepoState()` … 27 lines … `state = ConnectionState(phase: connecting, …)` ~1308 | move the call to immediately **after** the `state =` assignment |
| backend switch ~1764 | manager `disconnect()`, `_invalidateRepoState()`, … | move the call after that path's `state =` assignment |
| provisioning ~2331 | `_invalidateRepoState()`, then flip | move after the flip |
| `disconnect()` ~2580 | `_invalidateRepoState()`, then `state = const ConnectionState()` | swap the two lines |

Leave `openRepo()` ~2515 alone (client is alive; see Out of scope), and add
a one-line comment there saying why it is deliberately different, so the
next reader does not "fix" it into inconsistency.

Add the rule as a comment on `_invalidateRepoState` itself:

> Call this **after** publishing the new [ConnectionState], never before.
> Invalidating a repo family refetches immediately when the panes are
> listening; if the UI still believes the old session is live, that refetch
> lands on a transport that is gone and surfaces as an error in the
> Repository panel and the file view (MADR 0018).

### 3b. The ordering test

`test/connection_invalidate_order_test.dart` — assert the *observable*
consequence, not the source order, so it survives refactoring:

1. `'disconnect publishes the disconnected state before refetching'`
   - Connect a stub session, mount a listener on `statusProvider(repo)`
     that records `(phase at call, clientAttached)` via a recording
     executor.
   - Call `disconnect()`.
   - Assert **no** recorded attempt has `phase == connected` with no client.
2. `'a reconnect does not refetch against the torn-down client'`
   - Same, driving `connect()` on an already-connected session.

**Deletion check:** restore either original order and confirm the matching
test fails.

**Verify:** `flutter analyze`;
`flutter test test/connection_invalidate_order_test.dart test/connection_race_test.dart test/connection_env_reset_test.dart test/connection_cycle_regression_test.dart`.

**Halt if:** moving the call in `connect()` breaks
`connection_race_test.dart`'s superseded-connect cases. That suite encodes
real ordering guarantees; if they conflict, stop and report which guarantee
is at stake rather than loosening a test.

---

## Phase 4 — A not-ready transport renders as loading (commit)

**Files**

* **Edit** `lib/core/utils/display_error.dart`
* **Edit** `lib/features/repository/repo_status_view.dart` (~1671)
* **Edit** `lib/features/repository/file_view.dart` (~722)
* **Edit** `lib/features/forge/forge_widgets.dart` (~183)
* **Edit** `test/repo_status_view_test.dart`, `test/file_view_test.dart`,
  `test/forge_list_error_test.dart`
* **Create** `test/no_developer_strings_test.dart`

### 4a. The predicate

In `display_error.dart`, beside `looksLikeAuthFailure`:

```dart
/// True when the failure means "the session is not up yet", not "your
/// command failed" — a command issued during a connect, or after a drop
/// cleared the client. The panes render these as a spinner: the work will
/// re-run on its own once the session settles.
bool isTransportNotReady(Object error) => error is SSHTransportNotReady;
```

A predicate rather than a bare `is` check at three call sites, so the
concept has one name and one place to grow.

### 4b. The three panes

Each already has the shape

```dart
if (pending && looksLikeAuthFailure(err)) {
  return const Center(child: ProgressCircle());
}
```

Extend the condition — not a second branch:

```dart
if (isTransportNotReady(err) || (pending && looksLikeAuthFailure(err))) {
  return const Center(child: ProgressCircle());
}
```

Note the asymmetry, and keep it: the auth case needs `pending`, because a
settled login that still says "not logged in" is a real error the user must
see. A not-ready transport needs no gate — it is never a user-actionable
failure, whatever the phase.

### 4c. Pane tests

One per pane, beside the existing spinner tests:

* `'a not-ready transport shows a spinner, not an error'` — override the
  pane's provider to throw `const SSHTransportNotReady('git status')` with
  `forgeAuthPending: false`; expect `ProgressCircle`, expect
  `find.textContaining('not ready')` and `find.textContaining('connecting')`
  to find nothing (the spinner replaces text entirely).
* Use the established teardown protocol (`_unmount`) — a mounted
  `ProgressCircle` fails `!timersPending`.

### 4d. The scan

`test/no_developer_strings_test.dart` — the guard that makes criterion 3
enforced rather than reviewed, in the repo's canon-scan idiom
(`button_cursor_canon_test.dart`):

* `'no user-facing path can render a developer error string'`
* Scan `lib/**.dart` for the literal `SSH connection not established`.
* Expect zero hits. Allowlist empty.
* Reason string: name `SSHTransportNotReady` and `humanizeSshError`, and say
  that a condition a user can reach needs a type and a humanized message.

**Verify:** `flutter analyze`;
`flutter test test/repo_status_view_test.dart test/file_view_test.dart test/forge_list_error_test.dart test/no_developer_strings_test.dart test/transport_readiness_race_test.dart` — Phase 1's reproduction must now **pass**.

---

## Phase 5 — Full gate (no extra commit if clean)

```sh
flutter analyze
dart format --output=none --set-exit-if-changed <every file this plan touched>
flutter test test/transport_readiness_race_test.dart \
  test/readiness_gated_executor_test.dart \
  test/connection_invalidate_order_test.dart \
  test/connection_race_test.dart \
  test/connection_cycle_regression_test.dart \
  test/connection_env_reset_test.dart \
  test/ssh_error_messages_test.dart \
  test/ssh_command_executor_test.dart \
  test/repo_status_view_test.dart \
  test/file_view_test.dart \
  test/forge_list_error_test.dart \
  test/no_developer_strings_test.dart \
  test/provider_retry_policy_test.dart
flutter test
```

Then hand back to the maintainer: `./build_macos.sh --unsigned --install`
and a cold connect to a remote repo. The symptom is gone, or Phase 1's
reproduction did not capture the real trigger and this plan is not finished.

## Verification

| # | Check |
|---|---|
| 1 | Phase 1's reproduction fails before Phase 1c and passes after |
| 1b | `transportSettled` settles on success, failure and supersession; `isTransportReady` requires state **and** client |
| 1c | Gate contract: ready ⇒ forward; nothing in flight ⇒ immediate throw; in flight ⇒ bounded wait; grace ⇒ throw. Ready path allocates no timer |
| 1d | No `CircularDependencyError`: the decorator reads `connectionProvider.notifier` only at call time |
| 2 | `SSHTransportNotReady` thrown at both executor sites; `humanizeSshError` maps it |
| 3 | The scan finds no `SSH connection not established` anywhere in `lib/` |
| 4 | All three panes spinner on a not-ready transport; the auth case still requires `forgeAuthPending` |
| 5 | Four lifecycle sites publish state before invalidating; restoring either order fails a test |
| 6 | `openRepo()` unchanged, with a comment saying why |
| 7 | `provider_retry_policy_test.dart` — 5 tests, unchanged, passing |
| 8 | analyze exit 0; touched files format-clean; full suite green |
| 9 | Maintainer confirms on a real cold connect |

## Rollout and Rollback

**Rollout.** One new exception type, one predicate, one condition widened in
three panes, four statements moved. No schema, no transport behaviour, no
dependency change.

**Rollback.** Revert phases in reverse. Phase 4's pane tests depend on
Phase 2's type; Phase 3 stands alone.

**Risks**

* Phase 3 moves statements inside the connection lifecycle, the most
  timing-sensitive code in the app. `connection_race_test.dart`,
  `connection_cycle_regression_test.dart` and `connection_env_reset_test.dart`
  are the net; all three are in the phase's verify list for that reason.
* Phase 1 may not reproduce, which invalidates the plan's premise. That is
  a halt, not a workaround.
* Widening the pane condition risks swallowing a *real* failure if
  `SSHTransportNotReady` were ever thrown for something other than a missing
  client. It is thrown at exactly two sites, both guarded by
  `client == null`; keep it that way.

## Halt conditions (do not improvise)

1. Phase 1 cannot reproduce the symptom → stop, report, chase the listed
   candidates. Do not write Phases 2–4 blind.
2. Phase 1 reproduces a trigger **outside** the four lifecycle paths → stop,
   extend MADR 0018's fix list, get approval, then continue.
3. Phase 3 breaks a `connection_race_test.dart` guarantee → report which,
   do not loosen the test.
4. Anyone proposes re-enabling provider retry, or making the executor wait
   unconditionally for a client → refused by MADR 0018 options B and D.
5. The gate ever waits when nothing is in flight → the contract is broken;
   that is the stall the short-circuit exists to prevent. Fix the
   `isSettled` callback, never lengthen the grace to compensate.
6. `CircularDependencyError` appears → a callback became a `watch`. Revert
   to the callback; do not "solve" it by moving the decorator.
