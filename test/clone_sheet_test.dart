// CloneRepositorySheet: submit gating, URL name derivation, the running-state
// footer (progress + Cancel), the connected-SSH registration path (repo
// persisted + activated), and the landing mode's destination picker.

import 'dart:async';

import 'package:flutter/widgets.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/forge/forge.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/storage/connection_store.dart';
import 'package:remote_magic_git/core/storage/saved_connection.dart';
import 'package:remote_magic_git/core/workspace/clone_controller.dart';
import 'package:remote_magic_git/features/common/buttons.dart';
import 'package:remote_magic_git/features/workspace/clone_sheet.dart';

import 'helpers/create_repo_harness.dart'
    show RecordingTabs, installTabs, destinationPopup;

class _FakeHandle implements SSHStreamHandle {
  final _stdout = StreamController<String>.broadcast();
  final _stderr = StreamController<String>.broadcast();
  final exit = Completer<int?>();
  @override
  Stream<String> get stdout => _stdout.stream;
  @override
  Stream<String> get stderr => _stderr.stream;
  @override
  Future<int?> get exitCode => exit.future;

  Future<void> finish(int? code) async {
    if (!exit.isCompleted) exit.complete(code);
    await _stdout.close();
    await _stderr.close();
  }

  @override
  Future<void> cancel() => finish(null);
}

class _FakeExecutor extends SSHCommandExecutor {
  final List<List<String>> calls = [];
  final List<List<String>> streamCalls = [];
  final List<SSHCommandResult> results = [];
  _FakeHandle handle = _FakeHandle();

  _FakeExecutor() : super(SSHClientManager());

  @override
  Future<SSHCommandResult> execute({
    required String repoPath,
    required List<String> gitArgs,
    Map<String, String>? extraEnv,
    String? stdin,
    Duration timeout = SSHCommandExecutor.defaultTimeout,
    int retries = 0,
    ExecLane lane = ExecLane.exclusive,
    bool compress = false,
    Duration? activityIdle,
    OperationDescriptor? operation,
    OperationEventCallback? onOperationEvent,
    CommandOutputCallback? onOutput,
  }) async {
    calls.add(gitArgs);
    return results.isNotEmpty
        ? results.removeAt(0)
        : const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  @override
  Future<SSHStreamHandle> executeStream({
    required String repoPath,
    required List<String> gitArgs,
    Map<String, String>? extraEnv,
    Duration openTimeout = SSHCommandExecutor.defaultTimeout,
    OperationDescriptor? operation,
    OperationEventCallback? onOperationEvent,
  }) async {
    streamCalls.add(gitArgs);
    return handle;
  }
}

/// Pins a fixed connection state and records setRepoPath calls.
class _StubConnection extends ConnectionController {
  _StubConnection(this._state);
  final ConnectionState _state;
  final List<String> repoPathsSet = [];

  /// Gates [beginProvisioning] so a test can hold a host "still dialing" while
  /// it drives the sheet — the window in which 0022 H4 happens.
  Completer<int?>? dialGate;
  final List<String> dialed = [];
  final List<int> aborted = [];

  @override
  ConnectionState build() => _state;

  @override
  void setRepoPath(String path) => repoPathsSet.add(path);

  @override
  Future<int?> beginProvisioning(SavedConnection conn) {
    dialed.add(conn.id);
    final gate = dialGate;
    if (gate == null) return Future.value(1);
    return gate.future;
  }

  /// Gates [abortProvisioning] so a test can hold a hang-up in flight while it
  /// disposes the sheet — the window in which MADR 0034 F4 happens.
  Completer<void>? abortGate;

  @override
  Future<void> abortProvisioning(int token) async {
    aborted.add(token);
    await abortGate?.future;
  }

  /// Recorded, never run (MADR 0036: every SSH clone provisions; without a
  /// tab host it finalizes here). `repoPathsSet` is "the path this session
  /// ended on", whichever call set it.
  final List<({int token, String repoPath})> finalized = [];

  @override
  Future<bool> finalizeProvisioned({
    required int token,
    required SavedConnection conn,
    required String repoPath,
    bool enableFsmonitor = false,
    String label = '',
    String gitDir = '',
  }) async {
    finalized.add((token: token, repoPath: repoPath));
    repoPathsSet.add(repoPath);
    return true;
  }

  final List<String> localConnects = [];

  @override
  Future<void> connectLocal(
    String repoPath, {
    String? label,
    String? id,
    String? mainRepoPath,
    String? gitDir,
  }) async {
    localConnects.add(repoPath);
  }
}

class _FakeStore extends ConnectionStore {
  final List<SavedConnection> updated = [];
  @override
  Future<void> updateMetadata(SavedConnection conn) async => updated.add(conn);
  @override
  Future<void> touch(String id, {DateTime? when}) async {}
}

SSHCommandResult _ok(String stdout) =>
    SSHCommandResult(exitCode: 0, stdout: stdout, stderr: '');

const _conn = SavedConnection(
  id: 'c1',
  label: 'Prod',
  host: 'h',
  port: 22,
  username: 'u',
  repoPath: '/srv/repo',
  repoPaths: ['/srv/repo'],
);

/// [pastDestination] advances off the Destination step the connected wizard
/// now opens on (MADR 0036, 2A) — see the create harness's twin.
Future<(_StubConnection, _FakeExecutor, _FakeStore)> _pumpConnected(
  WidgetTester tester, {
  bool pastDestination = true,
}) async {
  final stub = _StubConnection(
    const ConnectionState(
      phase: ConnectionPhase.connected,
      repoPath: '/srv/repo',
      repoPaths: ['/srv/repo'],
      connectionId: 'c1',
      connectionLabel: 'Prod',
      host: 'h',
    ),
  );
  final exec = _FakeExecutor();
  final store = _FakeStore();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        connectionProvider.overrideWith(() => stub),
        activeExecutorProvider.overrideWithValue(exec),
        connectionStoreProvider.overrideWithValue(store),
        savedConnectionsProvider.overrideWith((ref) async => [_conn]),
        gitServiceProvider.overrideWithValue(GitService(_FakeExecutor())),
      ],
      child: const MacosApp(
        debugShowCheckedModeBanner: false,
        home: CloneRepositorySheet.connected(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (pastDestination) await _next(tester);
  return (stub, exec, store);
}

Finder _cloneButton() => find.widgetWithText(AppPushButton, 'Clone');

Finder _continueButton() => find.widgetWithText(AppPushButton, 'Continue');

Finder _urlField() => find.byWidgetPredicate(
  (w) =>
      w is MacosTextField &&
      (w.placeholder ?? '').startsWith('https://github.com'),
);

/// Advances the wizard one step (the current step must be valid).
Future<void> _next(WidgetTester tester) async {
  await tester.tap(_continueButton());
  await tester.pumpAndSettle();
}

/// Connected-mode navigation: URL source → Location → Review.
Future<void> _toReviewViaUrl(WidgetTester tester, String url) async {
  await tester.tap(find.text('URL'));
  await tester.pumpAndSettle();
  await tester.enterText(_urlField(), url);
  await tester.pumpAndSettle();
  await _next(tester); // Source → Location
  await _next(tester); // Location → Review
}

void main() {
  // Don't wait out the green-bar flash before the success pop.
  CloneRepositorySheet.successPopDelay = Duration.zero;

  testWidgets('each step gates Continue until its inputs are valid', (
    tester,
  ) async {
    await _pumpConnected(tester);

    // Source step: URL tab with nothing entered yet.
    await tester.tap(find.text('URL'));
    await tester.pumpAndSettle();
    expect(tester.widget<AppPushButton>(_continueButton()).onPressed, isNull);

    await tester.enterText(
      _urlField(),
      'https://example.com/things/my-repo.git',
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<AppPushButton>(_continueButton()).onPressed,
      isNotNull,
    );
    await _next(tester); // Source → Location

    // Name was derived from the URL; parent prefilled from the active repo.
    expect(find.text('my-repo'), findsOneWidget);
    expect(
      tester.widget<AppPushButton>(_continueButton()).onPressed,
      isNotNull,
    );
    await _next(tester); // Location → Review

    expect(tester.widget<AppPushButton>(_cloneButton()).onPressed, isNotNull);
  });

  testWidgets('the progress bar tracks the current step left to right', (
    tester,
  ) async {
    // Deliberately renumbered: the connected wizard gained a Destination step
    // in front of Source (MADR 0036, 2A), so it is four steps, not three.
    await _pumpConnected(tester, pastDestination: false);
    expect(find.text('Step 1 of 4 — Target'), findsOneWidget);
    await _next(tester);
    expect(find.text('Step 2 of 4 — Source'), findsOneWidget);

    await tester.tap(find.text('URL'));
    await tester.pumpAndSettle();
    await tester.enterText(_urlField(), 'https://example.com/my-repo.git');
    await tester.pumpAndSettle();
    await _next(tester);
    expect(find.text('Step 3 of 4 — Location'), findsOneWidget);

    await _next(tester);
    expect(find.text('Step 4 of 4 — Review'), findsOneWidget);
  });

  testWidgets('a successful URL clone persists the repo and activates it', (
    tester,
  ) async {
    final (stub, exec, store) = await _pumpConnected(tester);
    await _toReviewViaUrl(tester, 'https://example.com/my-repo.git');

    exec.results.add(_ok('absent')); // probe
    await tester.tap(_cloneButton());
    await tester.pump();
    await tester.pump();

    // Running: Cancel visible, Clone gone.
    expect(find.widgetWithText(AppPushButton, 'Cancel'), findsOneWidget);
    expect(_cloneButton(), findsNothing);

    await exec.handle.finish(0);
    await tester.pumpAndSettle();

    expect(exec.streamCalls.single, [
      'git',
      'clone',
      '--progress',
      '--',
      'https://example.com/my-repo.git',
      'my-repo',
    ]);
    expect(stub.repoPathsSet, ['/srv/my-repo']);
    // Deliberately dropped: `store.updated…allRepoPaths`. The sheet no longer
    // persists the path; the real `finalizeProvisioned` does (MADR 0036, 3B).
    // Without a tab host this stub IS that tab, and `repoPathsSet` above is
    // its finalize.
    expect(stub.finalized.single.repoPath, '/srv/my-repo');
    expect(find.byType(CloneRepositorySheet), findsNothing, reason: 'popped');
  });

  // ---------------------------------------------------------------------
  // MADR 0032 Phase 7 — a clone records the namespace it came from, so the
  // create sheet's recency list is not empty for a user who only ever clones.
  // ---------------------------------------------------------------------

  /// Drives a URL clone of [url] to completion and returns the store.
  Future<_FakeStore> cloneUrl(WidgetTester tester, String url) async {
    final (_, exec, store) = await _pumpConnected(tester);
    await _toReviewViaUrl(tester, url);
    exec.results.add(_ok('absent')); // probe
    await tester.tap(_cloneButton());
    await tester.pump();
    await tester.pump();
    await exec.handle.finish(0);
    await tester.pumpAndSettle();
    return store;
  }

  testWidgets('a nested GitLab clone records its namespace', (tester) async {
    final store = await cloneUrl(
      tester,
      'https://gitlab.com/team/subgroup/my-repo.git',
    );

    expect(
      store.updated
          .map((c) => c.namespacesFor('gitlab@gitlab.com'))
          .where((l) => l.isNotEmpty)
          .toList(),
      [
        ['team/subgroup'],
      ],
      reason: 'the namespace is the path minus the project',
    );
  });

  testWidgets('a GitHub clone records the owner', (tester) async {
    final store = await cloneUrl(tester, 'git@github.com:owner/my-repo.git');

    expect(
      store.updated
          .map((c) => c.namespacesFor('github@github.com'))
          .where((l) => l.isNotEmpty)
          .toList(),
      [
        ['owner'],
      ],
      reason: 'scp-style URLs parse the same as https ones',
    );
  });

  testWidgets('a clone from a non-forge host records nothing', (tester) async {
    // No forge account to key history by, so there is nothing to remember.
    final store = await cloneUrl(
      tester,
      'https://example.com/team/my-repo.git',
    );

    expect(store.updated.every((c) => c.namespaceHistory.isEmpty), isTrue);
  });

  testWidgets('a clone with no namespace in the path records nothing', (
    tester,
  ) async {
    // `host/project` has no group above it — the account's own namespace,
    // which is already first in the creatable list.
    final store = await cloneUrl(tester, 'https://gitlab.com/my-repo.git');

    expect(store.updated.every((c) => c.namespaceHistory.isEmpty), isTrue);
  });

  testWidgets('a failed clone records no namespace', (tester) async {
    final (_, exec, store) = await _pumpConnected(tester);
    await _toReviewViaUrl(
      tester,
      'https://gitlab.com/team/subgroup/my-repo.git',
    );

    exec.results.add(_ok('absent')); // probe
    exec.results.add(_ok('absent')); // cleanup probe
    await tester.tap(_cloneButton());
    await tester.pump();
    await tester.pump();
    await exec.handle.finish(128); // the clone itself fails
    await tester.pumpAndSettle();

    expect(
      find.byType(CloneRepositorySheet),
      findsOneWidget,
      reason: 'non-vacuous: the sheet stayed open on the failure',
    );
    expect(
      store.updated.every((c) => c.namespaceHistory.isEmpty),
      isTrue,
      reason: 'a namespace never cloned from is not a namespace used',
    );
  });

  // -------------------------------------------------------------------------
  // MADR 0036 Phase 2 — today's connected behaviour, pinned (clone).
  // Phase 5 inverts the first two on purpose and must say so.
  // -------------------------------------------------------------------------
  testWidgets(
    'a connected SSH clone provisions in its own tab and leaves the current '
    'tab alone',
    (tester) async {
      // Deliberately inverted from the Phase 2 pin "lands in the current
      // tab": MADR 0036 decision 3B.
      final (stub, exec, _) = await _pumpConnected(tester);
      final tabs = RecordingTabs(tabExecutor: exec);
      installTabs(tabs);
      await _toReviewViaUrl(tester, 'https://example.com/my-repo.git');
      exec.results.add(_ok('absent')); // probe, on the shared executor
      await tester.tap(_cloneButton());
      await tester.pump();
      await tester.pump();

      // Progress is read from the tab running the job: Cancel is offered.
      expect(find.widgetWithText(AppPushButton, 'Cancel'), findsOneWidget);
      expect(tabs.opened, hasLength(1), reason: 'one tab was opened');
      final spawned = tabs.spawned.single;
      expect(spawned.dialed.single.id, 'c1', reason: 'dialled there');

      await exec.handle.finish(0);
      await tester.pumpAndSettle();

      expect(exec.streamCalls.single.take(2), ['git', 'clone']);
      expect(spawned.finalized.single.repoPath, '/srv/my-repo');
      expect(stub.repoPathsSet, isEmpty, reason: 'this tab did not switch');
      expect(stub.dialed, isEmpty);
      expect(find.byType(CloneRepositorySheet), findsNothing, reason: 'popped');
    },
  );

  testWidgets('a connected clone sheet shows the Destination step', (
    tester,
  ) async {
    // Deliberately inverted from the Phase 2 pin: MADR 0036 decision 2A.
    await _pumpConnected(tester, pastDestination: false);
    expect(destinationPopup(), findsOneWidget);
  });

  testWidgets('a clone refuses at the tab cap and runs nothing', (
    tester,
  ) async {
    final (stub, exec, _) = await _pumpConnected(tester);
    final tabs = RecordingTabs(tabExecutor: exec)..capReached = true;
    installTabs(tabs);
    await _toReviewViaUrl(tester, 'https://example.com/my-repo.git');

    expect(tester.widget<AppPushButton>(_cloneButton()).onPressed, isNull);
    expect(find.text(CloneRepositorySheet.capMessage), findsOneWidget);
    expect(exec.streamCalls, isEmpty);
    expect(stub.dialed, isEmpty);
    expect(tabs.connectRan, 0);
  });

  testWidgets('cancelling a routed clone reaches the tab running the job', (
    tester,
  ) async {
    final (_, exec, _) = await _pumpConnected(tester);
    final tabs = RecordingTabs(tabExecutor: exec);
    installTabs(tabs);
    await _toReviewViaUrl(tester, 'https://example.com/my-repo.git');
    exec.results.add(_ok('absent'));
    exec.results.add(_ok('absent')); // cleanup probe after cancel
    await tester.tap(_cloneButton());
    await tester.pump();
    await tester.pump();
    final runningIn = tabs.tabs.single.container;
    expect(runningIn.read(cloneJobProvider).isRunning, isTrue);

    await tester.tap(find.widgetWithText(AppPushButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(
      runningIn.read(cloneJobProvider).isRunning,
      isFalse,
      reason: 'the cancel went to the container running the job',
    );
    expect(find.byType(CloneRepositorySheet), findsOneWidget);
  });

  testWidgets('a failed clone keeps the sheet open with the error', (
    tester,
  ) async {
    final (stub, exec, _) = await _pumpConnected(tester);
    await _toReviewViaUrl(tester, 'https://example.com/my-repo.git');

    exec.results.add(_ok('absent')); // probe
    exec.results.add(_ok('absent')); // cleanup probe (nothing left behind)
    await tester.tap(_cloneButton());
    await tester.pump();
    await tester.pump();

    exec.handle.emitFatal();
    await exec.handle.finish(128);
    await tester.pumpAndSettle();

    expect(find.byType(CloneRepositorySheet), findsOneWidget);
    expect(find.textContaining('not found'), findsOneWidget);
    expect(stub.repoPathsSet, isEmpty, reason: 'no activation on failure');
  });

  testWidgets('landing mode: switching to GitLab tab auto-populates host from '
      'forge auth when _hostEdited is false', (tester) async {
    final stub = _StubConnection(const ConnectionState());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          connectionProvider.overrideWith(() => stub),
          activeExecutorProvider.overrideWithValue(_FakeExecutor()),
          savedConnectionsProvider.overrideWith((ref) async => [_conn]),
          forgeRepoListProvider.overrideWith((ref, key) async => []),
          // Return a self-hosted GitLab host to simulate the signed-in CLI
          // probe result — the host field should auto-populate after switching
          // to the GitLab tab.
          forgeAuthHostProvider.overrideWith((ref, key) async {
            final (forge, _) = key;
            return forge == Forge.gitlab ? 'gitlab.example.com' : null;
          }),
        ],
        child: const MacosApp(
          debugShowCheckedModeBanner: false,
          home: CloneRepositorySheet.landing(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _next(tester); // Destination → Source

    // Switch from the default GitHub tab to GitLab.
    await tester.tap(find.text('GitLab'));
    await tester.pumpAndSettle();

    // The host field should now show the forge-auth host (not the stock
    // 'gitlab.com') because the _hostEdited flag was reset after the
    // programmatic tab-switch host change.
    final hostField = find.byWidgetPredicate(
      (w) =>
          w is MacosTextField &&
          w.controller != null &&
          w.controller!.text == 'gitlab.example.com',
    );
    expect(
      hostField,
      findsOneWidget,
      reason:
          'host field should auto-populate to the forge auth host '
          'after switching to GitLab tab',
    );
  });

  testWidgets('landing mode offers This Mac plus saved connections', (
    tester,
  ) async {
    final stub = _StubConnection(const ConnectionState());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          connectionProvider.overrideWith(() => stub),
          activeExecutorProvider.overrideWithValue(_FakeExecutor()),
          savedConnectionsProvider.overrideWith((ref) async => [_conn]),
          // The default GitHub tab lists repos through the LOCAL executor for
          // a This-Mac destination — stub the listing (and the auth-host
          // prefill probe) so the test never spawns a real gh process.
          forgeRepoListProvider.overrideWith((ref, key) async => []),
          forgeAuthHostProvider.overrideWith((ref, key) async => null),
        ],
        child: const MacosApp(
          debugShowCheckedModeBanner: false,
          home: CloneRepositorySheet.landing(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The landing wizard opens on Destination (section caption + breadcrumb).
    expect(find.text('Target'), findsWidgets);
    expect(find.text('This Mac'), findsOneWidget);
    await _next(tester); // Destination → Source

    // Local target by default: on the Location step, the native-picker row
    // is shown, not the host path field.
    await tester.tap(find.text('URL'));
    await tester.pumpAndSettle();
    await tester.enterText(_urlField(), 'https://example.com/my-repo.git');
    await tester.pumpAndSettle();
    await _next(tester); // Source → Location

    expect(find.text('Parent folder on this Mac'), findsOneWidget);
    expect(find.text('No folder chosen'), findsOneWidget);
    expect(find.text('Parent folder on the host'), findsNothing);
  });

  testWidgets('the destination cannot be switched while a host is dialing', (
    tester,
  ) async {
    // 0022 H4, UI half. Switching destination mid-dial is what lets a session
    // dialed for host A be adopted under host B — so the control is dead for
    // the duration of the dial. (The post-await identity guard in
    // WorkspaceProvisioning and the controller's own conn-id check are the
    // backstops, covered in connection_provisioning_test.)
    //
    // Re-pointed for MADR 0036 (6B): selection no longer dials. The dial
    // starts at the first commitment to the host — Browse… on the Location
    // step — and the user can walk Back to the Destination step meanwhile.
    //
    // Note: no pumpAndSettle once the dial starts — the sheet shows an
    // indeterminate "Connecting…" spinner, which never settles.
    final stub = _StubConnection(const ConnectionState());
    stub.dialGate = Completer<int?>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          connectionProvider.overrideWith(() => stub),
          activeExecutorProvider.overrideWithValue(_FakeExecutor()),
          savedConnectionsProvider.overrideWith((ref) async => [_conn]),
          forgeRepoListProvider.overrideWith((ref, key) async => []),
          forgeAuthHostProvider.overrideWith((ref, key) async => null),
        ],
        child: const MacosApp(
          debugShowCheckedModeBanner: false,
          home: CloneRepositorySheet.landing(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    MacosPopupButton<String?> destination() => tester
        .widgetList<MacosPopupButton<String?>>(
          find.byType(MacosPopupButton<String?>),
        )
        .first;

    expect(
      destination().onChanged,
      isNotNull,
      reason: 'enabled before any dial',
    );

    // Select the saved connection: no dial yet (6B).
    await tester.tap(find.text('This Mac'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Prod').last);
    await tester.pumpAndSettle();
    expect(stub.dialed, isEmpty, reason: 'selection does not dial');

    // Commit to the host: Browse… on the Location step starts the (gated) dial.
    await _next(tester); // Destination → Source
    await tester.tap(find.text('URL'));
    await tester.pumpAndSettle();
    await tester.enterText(_urlField(), 'https://example.com/my-repo.git');
    await tester.pumpAndSettle();
    await _next(tester); // Source → Location
    await tester.tap(find.widgetWithText(AppPushButton, 'Browse…').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(stub.dialed, ['c1'], reason: 'the dial should have started');

    // Walk back to Destination while it dials: the control is inert.
    await tester.tap(find.widgetWithText(AppPushButton, 'Back'));
    await tester.pump();
    await tester.tap(find.widgetWithText(AppPushButton, 'Back'));
    await tester.pump();
    expect(
      destination().onChanged,
      isNull,
      reason: 'destination must be inert while the host is still dialing',
    );

    // Once the dial lands the control comes back, or the sheet is stuck.
    stub.dialGate!.complete(7);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    // The dial's continuation opened the directory browser; dismiss it.
    await tester.tap(
      find
          .byWidgetPredicate((w) => w is MacosTooltip && w.message == 'Close')
          .last,
    );
    await tester.pumpAndSettle();
    expect(
      destination().onChanged,
      isNotNull,
      reason: 'the control must be usable again once the dial resolves',
    );
  });

  testWidgets(
    'switching destination mid-hang-up does not setState on a disposed sheet',
    (tester) async {
      // The clone sheet's `_onDestChanged` is byte-identical to the create
      // sheet's, so this mirrors that test rather than trusting two copies to
      // stay in step (MADR 0034 F4).
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      final stub = _StubConnection(const ConnectionState())
        ..abortGate = Completer<void>();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            connectionProvider.overrideWith(() => stub),
            activeExecutorProvider.overrideWithValue(_FakeExecutor()),
            savedConnectionsProvider.overrideWith((ref) async => [_conn]),
            forgeRepoListProvider.overrideWith((ref, key) async => []),
            forgeAuthHostProvider.overrideWith((ref, key) async => null),
          ],
          child: const MacosApp(
            debugShowCheckedModeBanner: false,
            home: CloneRepositorySheet.landing(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Adopt a session, so resetProvisioning has a token to hang up. Under
      // MADR 0036 (6B) selection no longer dials: Browse… on the Location
      // step is the first commitment to the host.
      await tester.tap(find.byType(MacosPopupButton<String?>));
      await tester.pumpAndSettle();
      await tester.tap(find.text(_conn.displayName).last);
      await tester.pumpAndSettle();
      await _next(tester); // Destination → Source
      await tester.tap(find.text('URL'));
      await tester.pumpAndSettle();
      await tester.enterText(_urlField(), 'https://example.com/my-repo.git');
      await tester.pumpAndSettle();
      await _next(tester); // Source → Location
      await tester.tap(find.widgetWithText(AppPushButton, 'Browse…').first);
      await tester.pumpAndSettle();
      expect(stub.dialed, ['c1'], reason: 'Browse… adopted a session');
      await tester.tap(
        find
            .byWidgetPredicate((w) => w is MacosTooltip && w.message == 'Close')
            .last,
      );
      await tester.pumpAndSettle();

      // Back to Destination, switch to This Mac: the hang-up parks.
      await tester.tap(find.widgetWithText(AppPushButton, 'Back'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(AppPushButton, 'Back'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(MacosPopupButton<String?>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('This Mac').last);
      await tester.pump();
      expect(stub.aborted, [1], reason: 'the hang-up must be in flight');

      // The sheet goes away while the hang-up is still outstanding.
      await tester.pumpWidget(const MacosApp(home: Text('gone')));
      await tester.pump();
      stub.abortGate!.complete();
      await tester.pumpAndSettle();

      expect(
        tester.takeException(),
        isNull,
        reason: 'the resumed continuation must not touch a disposed State',
      );
    },
  );
}

extension on _FakeHandle {
  void emitFatal() => _stderr.add('fatal: repository not found\n');
}
