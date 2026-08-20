// CloneRepositorySheet: submit gating, URL name derivation, the running-state
// footer (progress + Cancel), the connected-SSH registration path (repo
// persisted + activated), and the landing mode's destination picker.

import 'dart:async';

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
import 'package:remote_magic_git/features/common/buttons.dart';
import 'package:remote_magic_git/features/workspace/clone_sheet.dart';

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

  @override
  ConnectionState build() => _state;

  @override
  void setRepoPath(String path) => repoPathsSet.add(path);
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

Future<(_StubConnection, _FakeExecutor, _FakeStore)> _pumpConnected(
  WidgetTester tester,
) async {
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
    await _pumpConnected(tester);
    expect(find.text('Step 1 of 3 — Source'), findsOneWidget);

    await tester.tap(find.text('URL'));
    await tester.pumpAndSettle();
    await tester.enterText(_urlField(), 'https://example.com/my-repo.git');
    await tester.pumpAndSettle();
    await _next(tester);
    expect(find.text('Step 2 of 3 — Location'), findsOneWidget);

    await _next(tester);
    expect(find.text('Step 3 of 3 — Review'), findsOneWidget);
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
    expect(
      store.updated.single.allRepoPaths,
      containsAll(['/srv/repo', '/srv/my-repo']),
    );
    expect(find.byType(CloneRepositorySheet), findsNothing, reason: 'popped');
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
    expect(find.text('Destination'), findsWidgets);
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
}

extension on _FakeHandle {
  void emitFatal() => _stderr.add('fatal: repository not found\n');
}
