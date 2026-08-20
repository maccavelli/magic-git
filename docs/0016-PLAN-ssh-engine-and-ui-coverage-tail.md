---
status: "proposed"
date: 2026-08-20
associated-madr: "0015-MADR-ssh-engine-and-ui-unit-test-gaps.md"
owner: [Maintainer]
target-milestone: Next work cycle (post-review)
---

# Implement the deferred tail of the 2026-08 coverage backlog (U9–U19)

Associated MADR:
[0015-MADR-ssh-engine-and-ui-unit-test-gaps.md](./0015-MADR-ssh-engine-and-ui-unit-test-gaps.md)

Companion to [0015-PLAN](./0015-PLAN-ssh-engine-and-ui-unit-test-gaps.md),
which executed the first tranche **U1–U8** (shipped in `39edbe0`) and listed
U9–U16 as explicitly out of scope. This plan is the execution vehicle for
that tail. It takes the next free number rather than reusing 0015 (whose
`NNNN-PLAN` filename is taken); the MADR pairing is in the frontmatter.

**Amended 2026-08-20, after U9–U16 were executed.** Running them surfaced
three findings the original audit could not have seen, now recorded as
**U17–U19** in the MADR. They are folded in here as Phases 9–11 rather
than deferred, because U17 invalidates the premise of every error-branch
widget test in the suite — including ones this plan just wrote — and
leaving it unaddressed would mean shipping tests that cannot fail.

A second engineer following only this file, against the tree at `39edbe0`
plus the U9–U16 working tree, must produce the same diff.

## Goal

Close the MEDIUM tail of MADR 0015 with tests that **fail if the cited
production branch is deleted**, at the honest scope the 2026-08-20
re-investigation established — three of the eight findings are smaller than
the MADR first recorded, and one moves suites.

**Acceptance criteria**

1. `ActivityCommandExecutor` forwards every `execute` parameter unchanged,
   substitutes `resolveDescriptor` only when `operation` is null, and
   substitutes its own `onOperationEvent` only when the caller passes none;
   `executeStream` never resolves a descriptor.
2. The Settings sheet's Command-timeouts help says the Network field is a
   *stall* budget and names the 30-minute ceiling.
3. Two profiles differing only by port re-probe the environment.
4. `AppShell` renders the in-session reconnect overlay while
   `connection.reconnecting` is true — interrupted headline, host, attempt
   number, Stop Retrying and Cancel — and does not render the landing card.
5. `NativeSshSocket` sets `tcpNoDelay` **and** Darwin `SO_KEEPALIVE` on a
   real loopback socket (read back via `getRawOption`), and a socket whose
   `setRawOption` throws still yields a usable connection.
6. `ConnectionForm`, `MergeOptionsSheet`, `RunJobsView` and the forge sheet
   atoms each build under a stub container, plus one error/empty path each
   where the widget has one.
7. Live sshd only: `attachedClientCount == 3` after a real connect; a short
   `ExecLane.read` completes while a long `ExecLane.sync` is draining.
8. Live sshd only: closing the sync client degrades to 2 and the backoff
   redial restores 3.
9. The app's provider retry policy is a single named value used by all
   three production scope sites and by a test helper; a widget test built
   through that helper reaches a provider's `error` branch, and the
   framework semantics that make this necessary are pinned by a test.
10. Every `MacosCheckbox` / `MacosRadioButton` label is clickable, via one
    canonical wrapper, enforced by a source scan with an allowlist.
11. The two sheet test seams are documented where a plan author will read
    them.
12. `flutter analyze` exit 0, `dart format` clean, full `flutter test`
    green. No `live-forge`. Nothing outside the live suite may require
    sshd. dartssh2 stays exact `3.3.0`; read-cap ceiling stays 4.

## Scope

| ID | Work | Suite | Notes |
|---|---|---|---|
| U12 | `ActivityCommandExecutor` forwarding | unit | reuses `test/helpers/mock_executor.dart` |
| U15 | Settings stall-budget copy | widget | one pump |
| U16 | Env-cache port key | unit | **LOW after correction** — username half already covered |
| U14 | In-session reconnect overlay | widget | `app_shell_test.dart` grows from 1 case |
| U10 | `SO_KEEPALIVE` best-effort | unit | needs a small production extract |
| U13 | Connection-form / forge-sheet smoke | widget | **narrowed after correction** |
| U9  | Live topology + read-during-sync | live sshd | `integration` tag, self-skips |
| U11 | Live sync-client redial | live sshd | **relocated** from unit |
| U17 | Shared provider retry policy + test helper + semantics pin | unit/widget | **amendment**; production: 3 call sites de-duplicated |
| U18 | `LabeledCheckbox` / `LabeledRadio` + canon scan | widget | **amendment**; production: 10 call sites |
| U19 | Sheet test-seam convention written down | docs | **amendment** |

**Out of scope** (do not implement, even if adjacent)

* The MADR's LOW bullets: per-atom tests for `field_styles`, `sheet_chrome`,
  `sidebar_branding`; Dashboard goldens; `HostKeyPrompt` value equality.
* Re-running or restarting [TEST_COVERAGE_PLAN.md](./TEST_COVERAGE_PLAN.md).
* dartssh3, read-cap raise, SFTP, `keepAliveInterval` non-null.
* Any change to transport behaviour. U10's extract is a pure refactor: the
  same two option calls, same order, same swallow.
* Full-panel suites for the U13 widgets. One build + one error path each.
* Migrating all ~113 bare-scope test files to the U17 helper. Only tests
  that assert an error branch need it; a blanket migration is churn with
  no signal. New tests use the helper.
* `MacosSwitch` labels (U18 scope note): `NSSwitch` has no title and
  AppKit does not toggle from an adjacent label. `ForgeSheetToggle` is
  left alone.
* Changing any `skipLoadingOnReload` default. `_dashboardSection`'s
  `true` is a deliberate UX choice (keep last-good rows, show the error
  inline); U17 removes the *accident* that it also masked a harness bug,
  not the choice itself.

## Prerequisites

* Commands: `flutter pub get`, `flutter analyze`, `flutter test`
  (`AGENTS.md`). New Dart analyzer-clean on the first pass.
* `dart format` the touched files before staging — the first tranche needed
  a reformat pass at the end; do not repeat that.
* `lib/core/providers/app_providers.dart` is classified as binary: search it
  with `rg -a`, and **never** with a `head`-truncated pipeline (that
  truncation is what produced the wrong U16 finding).
* Do not commit unless the user asks. If they ask for phase commits:
  `git add` only that phase's files, then `git commit --no-edit`.
  Never `-m` / `-F` / a heredoc.
* Never run `flutter test --run-skipped -t live-forge`.
* Halt rule: if a Phase 0 fact disagrees with this plan, stop and update
  this plan. Do not improvise.

## Phase 0 — Confirm facts (no commit)

Read, do not edit:

* `lib/core/exec/activity_command_executor.dart` — `execute` forwards 11
  parameters; `operation ?? resolveDescriptor(...)` (~50);
  `onOperationEvent ?? this.onOperationEvent` (~52); `executeStream`
  deliberately does **not** resolve (~62–77, and the comment saying why).
* `test/helpers/mock_executor.dart` — `MockExecCall` already records
  `activityIdle` (~146). Confirm whether it records `operation` /
  `onOperationEvent`; if not, extending it is Phase 1's first step.
* `lib/features/settings/settings_sheet.dart` ~178–187 — the
  `'Command timeouts'` section string containing `stall budget` and
  `30 minutes`.
* `lib/core/providers/app_providers.dart` ~867 —
  `_envKey` is `'${p.host}|${p.port}|${p.username}'`.
* `test/connection_env_reset_test.dart` ~291 — the username cache-miss case
  **already exists**. Add the port case beside it; do not duplicate it.
* `lib/features/app_shell.dart` ~1111–1122 — `if (connection.reconnecting)`
  returns `_ReconnectingOverlay(host, attempt, reason, onStopRetrying,
  onCancel)` *before* the `if (!connected) return ConnectionLanding()`
  branch. Overlay copy at ~164–229: `'Connection interrupted'`,
  `'Lost contact with <host>.'`, `'Reconnecting… (attempt N)'`,
  `'Disconnected for …'`, `'Stop Retrying'`, `'Cancel'`. The class is
  private — assert on text, not type.
* `lib/core/ssh/native_ssh_socket.dart` ~26–40 — `Socket.connect`, then
  `setOption(tcpNoDelay, true)`, then `setRawOption(SO_KEEPALIVE)` inside a
  bare `catch (_)`. `_soKeepAlive` is `0x0008` (Darwin).
* `test/ssh_live_transport_test.dart` — `@Tags(['integration'])`,
  `_DisposableSshd` (~46–150), `setUp` connects a fresh manager+executor per
  test (~172–190), `bool skip() => sshd == null` (~198). Its sshd config
  (~85–96) sets no `MaxSessions`/`MaxStartups`, so OpenSSH defaults
  (10 sessions, 10:30:100 startups) admit the triple handshake.
* `lib/core/ssh/ssh_client_manager.dart` — `_onSyncClientLost` (~662),
  `streamRedialDelay(0)` is **15 s**, `_maxRedialFailures`.
* The U13 targets and their current coverage, re-verified:
  `ConnectionForm` (`connection_switcher.dart` ~1011) — no test pumps it;
  `MergeOptionsSheet` / `showMergeOptionsSheet` (`gitlab_panel.dart` ~1255,
  `github_panel.dart` ~1214) — none; `RunJobsView` (`github_panel.dart`
  ~776/~955) — none; `ForgeSheetField`, `ForgeSheetToggle`,
  `SheetSubmitRow`, `FieldErrorNote`, `ForgeDiffPreview` — none.
  `HistoryView`, `AddExistingRepoSheet`, `ForgeMilestonePicker` and
  `ForgeRepositoryWorkspace` **are** covered — do not add to them.

Additional facts for the amendment (Phases 9–11):

* `retry: (_, _) => null` appears at exactly three production sites —
  `lib/main.dart` ~109, `lib/features/tabs/tabs_controller.dart` ~94,
  `lib/features/window/secondary_window_main.dart` ~157. Confirm the count
  is still three before Phase 9 replaces them.
* riverpod 3.3.2: `typedef Retry = Duration? Function(int retryCount,
  Object error)` (`src/core/provider_container.dart` ~293);
  `AsyncValue.when`'s `skipLoadingOnReload` defaults to `false` and its
  branch order is at `src/core/async_value.dart` ~250–262; `isReloading`
  is `_hasState && isLoading && this is AsyncLoading` (~97).
* `lib/features/forge/project_sections.dart` ~287 (`_dashboardSection`)
  passes `skipLoadingOnReload: true`; `lib/features/common/async_views.dart`
  ~268 (`asyncListSection`) exposes the same flag defaulting to `false`.
  Neither is being changed — read them so Phase 9d's expectations are
  right.
* The ten `MacosCheckbox` / `MacosRadioButton` sites in U18's table, and
  `lib/features/common/tappable.dart` +
  `lib/features/common/labeled_text_field.dart` as the shape precedents.
* `test/button_cursor_canon_test.dart` — the existing source-scan idiom
  (regex + per-file allowlist + a reason string naming the wrapper). Both
  new scans follow it; do not invent a second style.

**Halt if:** `ActivityCommandExecutor` no longer decorates
`CommandExecutor`, the reconnect overlay has moved out of `AppShell`,
`_envKey` no longer includes the port, or the retry literal appears at a
fourth site. Update the MADR first.

---

## Phase 1 — U12 `ActivityCommandExecutor` forwarding (commit)

**Files**

* **Create** `test/activity_command_executor_test.dart`
* **Edit** `test/helpers/mock_executor.dart` — only if it does not already
  record `operation` / `onOperationEvent`; add the two fields to
  `MockExecCall` / `MockStreamCall` the way `activityIdle` is recorded.

**Tests**

1. `'execute forwards every parameter unchanged'`
   - Call with a non-default value for each of `extraEnv`, `stdin`,
     `timeout`, `retries`, `lane`, `compress`, `activityIdle`.
   - Assert the single recorded call carries each one verbatim.
   - **Deletion check:** dropping any forward from the decorator fails.
2. `'a null operation is filled from the resolver'`
   - Resolver returns a sentinel descriptor and records the
     `(repositoryPath, lane, argv)` it was handed.
   - Assert the inner call's `operation` is the sentinel and the resolver
     saw the same repo/lane/argv the caller passed.
3. `'an explicit operation wins over the resolver'`
   - Pass `operation:`; assert the resolver was **not** called and the
     inner call carries the caller's descriptor.
4. `'a caller callback wins over the decorator default'`
   - With and without `onOperationEvent:`; assert which callback the inner
     executor received (compare identity).
5. `'executeStream never resolves a descriptor'`
   - Call `executeStream` with no `operation`.
   - Assert the resolver was not called and `operation` reached the inner
     executor as null — this is the documented asymmetry
     (`activity_command_executor.dart` ~57–61), so a "fix" that starts
     resolving here must fail.
6. `'uploadBytes and configureEnvironment pass through'`
   - One assertion each, so a future decorator field cannot silently drop
     them.

**Verify:** `flutter analyze`;
`flutter test test/activity_command_executor_test.dart`.

---

## Phase 2 — U15 Settings stall-budget copy (commit)

**Files**

* **Edit** `test/settings_sheet_keymap_test.dart` (the file already pumps
  `SettingsSheet` with `SharedPreferences.setMockInitialValues({})` — reuse
  that setup rather than creating a second settings-pump file).

**Test**

`'the Command timeouts help calls Network a stall budget'`

* Pump `SettingsSheet` as the existing test does.
* `expect(find.textContaining('stall budget'), findsOneWidget)`
* `expect(find.textContaining('30 minutes'), findsOneWidget)`
* `expect(find.text('Network (fetch/pull/push), seconds'), findsOneWidget)`
* The section content may need `ensureVisible` first, as the keymap test
  does for its button.

Do **not** assert the whole paragraph — that is a golden in disguise and
will break on any wording tweak. The two phrases are the contract: a revert
to "command timeout" language fails.

**Verify:** `flutter analyze`;
`flutter test test/settings_sheet_keymap_test.dart`.

---

## Phase 3 — U16 env-cache port key (commit)

**Files**

* **Edit** `test/connection_env_reset_test.dart`

Append one block to the existing
`'same-host auto-reconnect reuses the env cache; disconnect invalidates'`
test, directly after the username case at ~291:

```dart
spy.events.clear();
await controller.connect(
  profile: const SSHConnectionProfile(host: 'mac', username: 'u', port: 2222),
  repoPath: '/repo',
);
expect(
  spy.events.where((e) => e == 'probe').length,
  1,
  reason: 'a different port must not hit the cache',
);
```

Do **not** add a second test function; the username case lives inline and
this is its sibling. Do **not** restate the username assertion.

**Verify:** `flutter analyze`;
`flutter test test/connection_env_reset_test.dart`.

---

## Phase 4 — U14 in-session reconnect overlay (commit)

**Files**

* **Edit** `test/app_shell_test.dart`

Add a `_StubConnection extends ConnectionController` (4 lines, the same
shape as `dashboard_sheet_test.dart`); do not import one from another test
file.

**Tests**

1. `'a dropped session shows the reconnect overlay, not the landing card'`
   - Override `connectionProvider` with a state where `reconnecting` is
     true, `host: 'admdevops'`, `reconnectAttempt: 2`,
     `error: 'Connection lost'`.
   - `expect(find.text('Connection interrupted'), findsOneWidget)`
   - `expect(find.textContaining('admdevops'), findsWidgets)`
   - `expect(find.textContaining('attempt 2'), findsOneWidget)`
   - `expect(find.text('Stop Retrying'), findsOneWidget)`
   - `expect(find.text('Cancel'), findsOneWidget)`
   - `expect(find.byType(ConnectionLanding), findsNothing)` — the ordering
     of the two branches at `app_shell.dart` ~1111/~1122 is the point.
   - **Deletion check:** removing the `if (connection.reconnecting)` branch
     drops through to the landing card and fails this.
2. `'the overlay suppresses a redundant reason line'`
   - Same state with `error: 'Connection lost'` → the bare reason string
     must **not** render as its own line (`app_shell.dart` ~176 skips it);
     with `error: 'kex exchange failed'` it must.
3. `'Stop Retrying calls stopReconnect'`
   - Tap it; assert against a stub controller that records the call.
     Do not drive the real auto-reconnect loop.

The overlay runs a 1-second elapsed-time ticker (`_ReconnectingOverlayState`
~125). Use discrete pumps, never `pumpAndSettle`, and unmount with
`pumpWidget(const SizedBox.shrink())` before the test ends — the same
protocol the U5 spinner tests use.

**Verify:** `flutter analyze`; `flutter test test/app_shell_test.dart`.

---

## Phase 5 — U10 `SO_KEEPALIVE` best-effort (commit)

**Files**

* **Edit** `lib/core/ssh/native_ssh_socket.dart` — extract the two option
  calls
* **Edit** `test/native_ssh_socket_test.dart`

### 5a. The extract (production)

`connect` calls `Socket.connect` itself, so the throw path is unreachable
without a seam. Extract exactly what is already there — no behaviour
change, same order, same swallow:

```dart
/// Applies the TCP options the handshake depends on. [SocketOption.tcpNoDelay]
/// is load-bearing; Darwin `SO_KEEPALIVE` is best-effort and its failure must
/// not fail a connect.
@visibleForTesting
static void applyTcpOptions(Socket socket) {
  socket.setOption(SocketOption.tcpNoDelay, true);
  try {
    socket.setRawOption(
      RawSocketOption.fromBool(
        RawSocketOption.levelSocket,
        _soKeepAlive,
        true,
      ),
    );
  } catch (_) {
    // Best-effort. tcpNoDelay is the load-bearing option.
  }
}
```

`connect` then calls `applyTcpOptions(socket)`. Needs
`import 'package:flutter/foundation.dart' show visibleForTesting;` — check
whether the file already has it before adding.

### 5b. Tests

1. `'connect applies tcpNoDelay and SO_KEEPALIVE on Darwin'`
   - Extend the existing loopback round-trip test rather than adding a
     third server: after `NativeSshSocket.connect`, read the option back on
     the underlying socket. Because `_socket` is private, assert on a
     socket the test owns:
     `final s = await Socket.connect(...); NativeSshSocket.applyTcpOptions(s);`
     then
     `expect(s.getRawOption(RawSocketOption(RawSocketOption.levelSocket, 0x0008, Uint8List(4))).any((b) => b != 0), isTrue)`.
   - Keep the existing round-trip assertions untouched.
2. `'a socket that rejects setRawOption still gets tcpNoDelay'`
   - `class _NoRawOptionSocket implements Socket` with a `noSuchMethod`
     forwarder, overriding only `setOption` (records the call, returns
     true) and `setRawOption` (throws `UnsupportedError`).
   - `expect(() => NativeSshSocket.applyTcpOptions(fake), returnsNormally)`
   - Assert the recorded `setOption` was `(tcpNoDelay, true)`.
   - **Deletion check:** removing the `try`/`catch` makes this throw.

**Halt if:** `getRawOption` for `SO_KEEPALIVE` throws on this machine —
then keep test 2 (the behaviour the finding is about) and drop the
read-back assertion with a comment; do not assert something weaker in its
place.

**Verify:** `flutter analyze`;
`flutter test test/native_ssh_socket_test.dart`.

---

## Phase 6 — U13 connection-form / forge-sheet smoke (commit)

**Files**

* **Create** `test/connection_form_test.dart`
* **Create** `test/merge_options_sheet_test.dart`
* **Create** `test/run_jobs_view_test.dart`
* **Create** `test/forge_sheet_widgets_test.dart`

One build path plus one error/empty path each. These are smoke tests: they
exist so a null-deref or a missing provider override in these screens shows
up in CI rather than on the Mac. Do not grow them into panel suites.

1. `connection_form_test.dart`
   - Pump `ConnectionForm` inside `MacosApp` with a `ProviderScope`.
   - Assert the host/username/port fields and the primary action render.
   - Assert saving with an empty host does not throw and does not close.
   - `SharedPreferences.setMockInitialValues(const {})`.
2. `merge_options_sheet_test.dart`
   - Pump `MergeOptionsSheet` directly (not `showMergeOptionsSheet`, which
     needs a route).
   - Assert the merge-method controls render; toggle squash and assert the
     returned options reflect it.
3. `run_jobs_view_test.dart`
   - Mirror `pipeline_jobs_view_test.dart`'s structure — read it first and
     follow its provider-override pattern.
   - One populated run, one empty/error run.
4. `forge_sheet_widgets_test.dart`
   - `ForgeSheetField` renders label + value and reports edits.
   - `ForgeSheetToggle` flips.
   - `FieldErrorNote` renders its message and nothing when null.
   - `SheetSubmitRow` disables submit while busy.
   - `ForgeDiffPreview` under a stubbed diff provider: loading → data, and
     the error path.

**Verify:** `flutter analyze`;
`flutter test test/connection_form_test.dart test/merge_options_sheet_test.dart test/run_jobs_view_test.dart test/forge_sheet_widgets_test.dart`.

---

## Phase 7 — U9 live topology and read-during-sync (commit)

**Files**

* **Edit** `test/ssh_live_transport_test.dart`

Both tests follow the file's contract: `if (skip()) return;` first, an
explicit `Timeout`, and no assumption that sshd exists.

1. `'a real connect attaches all three clients'`
   - After `setUp`'s connect: `expect(manager.attachedClientCount, 3)`
   - `expect(manager.syncClientDegraded, isFalse)`
   - `expect(manager.streamClientDegraded, isFalse)`
   - `expect(identical(manager.syncClient, manager.client), isFalse)` —
     the fallback getters return `_client` when degraded, so identity is
     what proves a *dedicated* third client.
   - `timeout: const Timeout(Duration(seconds: 60))`
2. `'a read completes while a long sync command is draining'`
   - Start `executor.execute(lane: ExecLane.sync, gitArgs: ['sh','-c','sleep 3; echo synced'])`
     without awaiting.
   - Wait for `executor.syncBusy`.
   - `await executor.execute(lane: ExecLane.read, gitArgs: ['echo','ok'])`
     and assert it returns `ok` **before** the sync future completes
     (record a `Stopwatch`; the read must finish well under 3 s).
   - Then await the sync and assert it succeeded.
   - This is the whole point of the third client: a fetch must not
     head-of-line-block reads.
   - `timeout: const Timeout(Duration(seconds: 60))`

**Verify:** `flutter analyze`;
`flutter test test/ssh_live_transport_test.dart` (self-skips without
`/usr/sbin/sshd`; on this Mac it runs).

---

## Phase 8 — U11 live sync-client redial (commit)

**Files**

* **Edit** `test/ssh_live_transport_test.dart`

`'a dropped sync client degrades, then the backoff redial restores it'`

* `if (skip()) return;`
* `expect(manager.attachedClientCount, 3)`
* Capture `final dropped = manager.syncClient;`
* `await dropped!.close();`
* Poll until `manager.syncClientDegraded` is true and
  `attachedClientCount == 2`.
* The first backoff is `streamRedialDelay(0)` = **15 s**. Poll for
  recovery with a ceiling of ~40 s; assert `attachedClientCount == 3`
  again and that `manager.syncClient` is **not** identical to `dropped`.
* `timeout: const Timeout(Duration(seconds: 90))`

This is the slowest test in the suite. It earns its place: the redial path
is the difference between one NAT drop and a session that stays degraded
for its whole life, and nothing else exercises it.

**Halt if:** recovery does not land inside 40 s — report the observed
timing; do not raise the ceiling past 60 s and do not weaken the assertion
to "degraded is fine".

**Verify:** `flutter test test/ssh_live_transport_test.dart`.

---

## Phase 9 — U17 one provider retry policy, shared by app and tests (commit)

**Files**

* **Create** `lib/core/providers/provider_retry_policy.dart`
* **Edit** `lib/main.dart`, `lib/features/tabs/tabs_controller.dart`,
  `lib/features/window/secondary_window_main.dart`
* **Create** `test/helpers/app_scope.dart`
* **Create** `test/provider_retry_policy_test.dart`
* **Edit** `test/run_jobs_view_test.dart`,
  `test/forge_sheet_widgets_test.dart` — replace the inline
  `retry: (_, _) => null` added in Phase 6 with the helper

### 9a. Name the policy once (production)

The three sites are byte-identical literals with three hand-written
comments. Replace the literal with a named function — Riverpod's own
`Retry` typedef is `Duration? Function(int retryCount, Object error)`, so a
top-level function is the idiomatic shared form and reads better at the
call site than a closure:

```dart
import 'package:riverpod/riverpod.dart' show Retry;

/// The app's provider [Retry] policy: never retry a failed provider.
///
/// Riverpod 3 retries by default (exponential backoff to ~6s). Magic Git's
/// provider failures are overwhelmingly deterministic — a bad path, a signed
/// out CLI, an HTTP 4xx — so a retry only delays the error the user needs to
/// see. Manual refresh and the remote watcher already re-drive on demand.
///
/// This is not merely a UX preference: under the default policy a failed
/// provider never emits [AsyncError] at all. It holds an [AsyncLoading] that
/// carries the prior error, so `isReloading` is true and `AsyncValue.when`
/// (whose `skipLoadingOnReload` defaults to false) renders `loading`
/// indefinitely. Every scope the app creates must use this, and so must any
/// test that expects to reach an error branch — see `test/helpers/app_scope.dart`
/// and `provider_retry_policy_test.dart`.
Duration? noProviderRetry(int retryCount, Object error) => null;
```

At each of the three sites: `retry: noProviderRetry`. Delete the local
comments — the rationale now lives with the policy — but keep any *other*
comment at those sites (`main.dart`'s note about `TabsHost` owning
`MacosApp`, `secondary_window_main.dart`'s executor-override note).

**No behaviour change.** `(_, _) => null` and `noProviderRetry` are the
same function.

### 9b. The test helper

`test/helpers/app_scope.dart`:

```dart
/// A [ProviderScope] configured the way the app configures its own — today
/// that means [noProviderRetry]. Use this instead of a bare ProviderScope in
/// any widget test, or the test runs the framework in a configuration the
/// app never uses and its error branches are unreachable.
ProviderScope appProviderScope({
  List<Override> overrides = const [],
  List<ProviderObserver> observers = const [],
  required Widget child,
});

/// The [ProviderContainer] equivalent, for tests that read providers directly
/// or drive an [UncontrolledProviderScope].
ProviderContainer appProviderContainer({
  List<Override> overrides = const [],
  List<ProviderObserver> observers = const [],
});
```

### 9c. Pin the semantics, not just the value

`test/provider_retry_policy_test.dart`. A test that only asserted
`noProviderRetry(1, e) == null` would be a tautology; pin the framework
behaviour that makes the policy load-bearing, so a Riverpod upgrade that
changes it fails here rather than silently re-breaking every error branch:

1. `'the policy never retries'` — `noProviderRetry(0, e)` and
   `noProviderRetry(5, e)` are null.
2. `'under the app policy a throwing provider reaches AsyncError'`
   - `appProviderContainer()`, a `FutureProvider` that throws, listened
     with `fireImmediately: true`.
   - Observed sequence is `AsyncLoading` → `AsyncError`; `when()` on the
     final state returns the `error` branch.
   - Repeat for a `StreamProvider` whose stream errors.
3. `'without the policy the provider never emits AsyncError'`
   - Same providers under a bare `ProviderContainer()`.
   - Assert every observed state `isLoading`, that none `is AsyncError`,
     that the post-failure state has `isReloading == true` and
     `hasError == true`, and that `when()` returns the **loading** branch.
   - This test documents the trap. Do **not** delete it as "asserting
     framework behaviour" — it is the reason the helper exists.
4. `'every production scope uses the policy'` — source scan over `lib/`
   in the style of `button_cursor_canon_test.dart`: every
   `ProviderScope(` / `ProviderContainer(` construction must have
   `retry:` within the following 8 lines. Allowlist by path, empty to
   start. `UncontrolledProviderScope` is exempt — it adopts a container
   someone else built.

### 9d. Adopt the helper where it matters

Switch the two Phase 6 files off their inline literal. Then, for each test
that asserts an error branch under a self-built scope, move it to the
helper: `create_repo_sheet_test.dart` and `forge_project_sections_test.dart`
are the two identified in the audit (the latter passes today only because
`_dashboardSection` sets `skipLoadingOnReload: true` — moving it to the
helper makes it pass for the *right* reason).

Do **not** migrate the rest of the suite. See Out of scope.

**Verify:** `flutter analyze`;
`flutter test test/provider_retry_policy_test.dart test/run_jobs_view_test.dart test/forge_sheet_widgets_test.dart test/create_repo_sheet_test.dart test/forge_project_sections_test.dart`.

**Halt if:** the `lib/` scan finds a fourth scope site this plan did not
name — stop and report it before changing it; a scope built somewhere
unexpected may be deliberate.

---

## Phase 10 — U18 clickable checkbox / radio labels (commit)

**Files**

* **Create** `lib/features/common/labeled_controls.dart`
* **Edit** the ten call sites listed below
* **Create** `test/labeled_controls_test.dart`
* **Edit** `test/button_cursor_canon_test.dart` — add the scan
* **Edit** `test/merge_options_sheet_test.dart` — drop the workaround

### 10a. The wrapper

`LabeledCheckbox` and `LabeledRadio<T>`, following
`labeled_text_field.dart`'s shape and naming. Each is the macos_ui control
plus a `Tappable` label that activates it — restoring what `NSButton` does
natively, since `macos_ui` ships only the glyph.

```dart
class LabeledCheckbox extends StatelessWidget {
  final String label;
  final bool value;
  /// Null disables the control *and* the label: Tappable with a null onTap
  /// keeps the arrow cursor, matching AppPushButton's disabled semantics.
  final ValueChanged<bool>? onChanged;
  final TextStyle? style;
  /// Wrap the label in [Expanded] (row-filling) vs sizing to content.
  final bool expand;
  ...
}

class LabeledRadio<T> extends StatelessWidget {
  final String label;
  final T value;
  final T? groupValue;
  final ValueChanged<T>? onChanged;
  ...
}
```

Rules the widget must encode:
* Gap between glyph and label matches today's sites: `SizedBox(width: 8)`
  (history_view's 5 becomes 8 — one spacing, not two).
* `onChanged == null` ⇒ the label is inert and shows the arrow.
* Toggling from the label produces the identical callback the glyph does
  (`!value` for checkbox, `value` for radio).

### 10b. Migrate the call sites

| file | line | control |
|---|---|---|
| `lib/features/forge/merge_options_sheet.dart` | ~113 | radio |
| `lib/features/forge/merge_options_sheet.dart` | ~128 | checkbox |
| `lib/features/branches/create_tag_sheet.dart` | ~203, ~235 | checkbox |
| `lib/features/worktrees/add_worktree_sheet.dart` | ~435, ~639, ~672 | checkbox |
| `lib/features/branches/branch_detail.dart` | ~1475 | checkbox |
| `lib/features/branches/branch_bulk_delete_sheet.dart` | ~328 | checkbox |
| `lib/features/history/history_view.dart` | ~1873 | checkbox (already correct — collapses onto the wrapper) |

`branch_bulk_delete_sheet.dart` ~328 has a trailing facts `Text` after the
label; keep it outside the wrapper. Preserve each site's existing
`Expanded`/`Flexible`/`const` shape and its disabled condition
(`create_tag_sheet` gates on `_submitting`).

### 10c. Pin it

`test/labeled_controls_test.dart`:
1. `'tapping the label toggles the checkbox'` — the callback fires with
   `!value`.
2. `'tapping the label selects the radio'` — fires with that option's
   value; an already-selected label is a no-op that still does not throw.
3. `'a disabled label is inert and keeps the arrow cursor'` —
   `onChanged: null`; no callback, `MouseRegion.cursor` is
   `SystemMouseCursors.basic`. Assert through the same `MouseRegion`
   lookup `tappable_cursor_test.dart` uses.
4. `'an enabled label shows the pointing hand'` —
   `SystemMouseCursors.click`.

Then extend the existing scan in `test/button_cursor_canon_test.dart`
(same file, same allowlist idiom — do not start a second canon file):

* `'no bare checkbox or radio outside the LabeledControls wrapper'`
* Regexes `(?<![A-Za-z_$])MacosCheckbox\(` and
  `(?<![A-Za-z_$])MacosRadioButton<`, skipping
  `lib/features/common/labeled_controls.dart`.
* Allowlist starts **empty**. If a site genuinely needs a bare glyph (a
  checkbox with no label at all), add it with a one-line reason, exactly
  as `_bareTapAllowance` documents its entries.
* Reason string names the wrapper, mirroring the existing messages.

### 10d. Drop the test workaround

`test/merge_options_sheet_test.dart` currently taps
`MacosRadioButton<MergeMethod>` at index 1 with a comment explaining the
label is not tappable. After 10b, tap the label text — that is the
behaviour under test — and delete the comment.

**Verify:** `flutter analyze`;
`flutter test test/labeled_controls_test.dart test/button_cursor_canon_test.dart test/merge_options_sheet_test.dart test/create_tag_sheet_test.dart test/add_worktree_sheet_test.dart test/history_actions_test.dart test/branches_view_test.dart`.

**Halt if:** a migrated site's existing test asserts on the bare `Text`
widget's position or type in a way the wrapper changes — fix the test to
assert the behaviour (tap the label, observe the toggle), not the tree
shape. Do not add a shape-preserving escape hatch to the wrapper.

---

## Phase 11 — U19 write down the sheet test seams (commit)

**Files**

* **Edit** `AGENTS.md`

Under the existing testing/architecture guidance, add a short subsection:
sheets come in two shapes, and each implies its test seam.

* **Public `*Sheet` widget** (~20: `SettingsSheet`, `DashboardSheet`,
  `AddWorktreeSheet`, `RecoverySheet`, `CloneRepositorySheet`, …) — the
  caller pushes it. A test pumps the widget directly.
* **Private body behind a public `show*` function that returns a result**
  (`showMergeOptionsSheet` → `_MergeOptionsBody`,
  `showBranchBulkDeleteSheet` → `_BulkDeleteSheet`, `promptForm` →
  `_PromptFormSheet`, `promptText` → `_PromptTextSheet`) — the function
  *is* the public API and its resolved value is the contract. A test pumps
  a host page, calls the function, drives the sheet, and asserts on what
  the future resolves to. Do not make the body public to test it.

Three sentences, not an essay: enough that a plan author picks the right
seam without reading the source. `AGENTS.md` is the file every agent
reads, and `CLAUDE.md` / `.goosehints` are symlinks to it — edit only
`AGENTS.md`.

**Verify:** no code change; `flutter analyze` and the suite are unaffected.
Confirm the symlinks still resolve: `ls -l CLAUDE.md .goosehints`.

---

## Phase 12 — Full gate (no extra commit if clean)

```sh
flutter analyze
dart format --output=none --set-exit-if-changed <every file this plan touched>
flutter test test/activity_command_executor_test.dart \
  test/settings_sheet_keymap_test.dart \
  test/connection_env_reset_test.dart \
  test/app_shell_test.dart \
  test/native_ssh_socket_test.dart \
  test/connection_form_test.dart \
  test/merge_options_sheet_test.dart \
  test/run_jobs_view_test.dart \
  test/forge_sheet_widgets_test.dart \
  test/ssh_live_transport_test.dart \
  test/provider_retry_policy_test.dart \
  test/labeled_controls_test.dart \
  test/button_cursor_canon_test.dart \
  test/tappable_cursor_test.dart \
  test/create_repo_sheet_test.dart \
  test/forge_project_sections_test.dart
flutter test
```

Never `live-forge`. The live sshd suite must still self-skip cleanly on a
machine without `/usr/sbin/sshd` — verify by reading `skip()` guards, not
by uninstalling sshd.

## Verification

| # | Check |
|---|---|
| 1 | `flutter analyze` exit 0; `dart format` clean |
| 2 | Full `flutter test` green; live suite skips cleanly without sshd |
| 3 | U12: all 11 execute params forwarded; resolver only on null operation; executeStream never resolves |
| 4 | U15: `stall budget` and `30 minutes` both present |
| 5 | U16: a port-only difference re-probes |
| 6 | U14: overlay wins over the landing card while reconnecting; Stop Retrying wired |
| 7 | U10: `SO_KEEPALIVE` readable on a real socket; a throwing `setRawOption` does not propagate |
| 8 | U13: four new smoke files, each with a build path and an error/empty path |
| 9 | U9: `attachedClientCount == 3` and `syncClient` not identical to `client`; read beats a 3 s sync |
| 10 | U11: close sync → 2 → redial → 3 with a *different* client object |
| 11 | dartssh2 exact `3.3.0`; ceiling still 4; no `keepAliveInterval:` other than `null` |
| 12 | U17: `noProviderRetry` is the only retry expression in `lib/`; the scan finds no unconfigured production scope; the semantics test shows `AsyncError` under the policy and `AsyncLoading(isReloading)` without it |
| 13 | U18: the canon scan finds no bare `MacosCheckbox(` / `MacosRadioButton<` outside the wrapper; label taps toggle; a disabled label keeps the arrow cursor |
| 14 | U19: `AGENTS.md` names both sheet seams; `CLAUDE.md` and `.goosehints` still resolve as symlinks to it |

Each test must fail if the cited production branch is deleted. A file with
a matching name closes nothing.

## Rollout and Rollback

**Rollout.** Tests, plus three production changes, all behaviour-preserving
refactors: `applyTcpOptions` (Phase 5a), the named `noProviderRetry` policy
replacing three identical literals (Phase 9a), and the
`LabeledCheckbox`/`LabeledRadio` wrapper (Phase 10) — which does change what
a user can click, restoring the AppKit behaviour `macos_ui` omits. No
settings schema, no transport change, no `.app` build unless asked.

Phase 10 is the only one worth eyeballing in the app: run
`./build_macos.sh --unsigned --install` afterwards if you want to confirm
the label hit areas feel right before the tag/worktree sheets ship.

**Rollback.** Revert phase commits in reverse order. Phase 5a must revert
with its tests or they will not compile. Nothing here is depended on by
0015-PLAN's tranche.

**Risks**

* Phases 7 and 8 add ~10 s and ~40 s of wall clock to a full `flutter test`
  on a machine with sshd. That is the cost of covering the only paths a
  fake cannot reach; if it becomes intolerable, the answer is a separate
  tag, not a weaker assertion.
* U13's four files pump screens nothing has pumped before — expect missing
  provider overrides on the first run. Add the override; do not stub out
  the screen.
* `getRawOption` behaviour for `SO_KEEPALIVE` is unverified on this
  machine; Phase 5's halt condition covers it.
* Phase 9d may turn previously-green error assertions red — that is the
  finding working, not a regression. A test that starts failing under the
  app's real policy was passing vacuously; fix the assertion, do not
  revert the scope.
* Phase 10 touches four sheets that have existing widget tests. Expect
  tree-shape assertions to need updating to behaviour assertions.

## Halt conditions (do not improvise)

1. A U13 screen cannot be pumped without a real transport → override the
   provider it reads; if that is not possible without new production
   surface, report it and skip that one screen. Do not weaken the others.
2. Phase 8's redial does not recover inside 40 s → report the timing; do
   not extend past 60 s or drop the assertion.
3. Any phase wants dartssh3, a read-cap raise, SFTP, or a non-null
   `keepAliveInterval` → stop; that is a different MADR.
4. A finding turns out to be already covered (as U11/U13/U16 partly were)
   → record the correction in MADR 0015 and shrink the phase. Do not write
   a duplicate test to satisfy the checklist.
5. Phase 9's `lib/` scan finds a scope site this plan did not name → stop
   and report before touching it; a container built somewhere unexpected
   may be deliberate.
6. Riverpod's observed behaviour disagrees with Phase 9c's table (for
   example a future version does emit `AsyncError` under the default
   policy) → the policy is still correct, but update the MADR's U17 table
   and this plan's rationale before writing the test. Never pin a
   behaviour you did not observe on this tree.
7. Phase 10's wrapper cannot preserve a call site's layout (a label that
   is not a plain string, a control with no label at all) → allowlist that
   site in the scan with a one-line reason, in the style of
   `_bareTapAllowance`. Do not add layout escape hatches to the wrapper,
   and do not skip the other nine.
