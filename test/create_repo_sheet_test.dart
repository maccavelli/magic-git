// CreateRepositorySheet: submit gating, plain git init argv + registration,
// the GitHub forge-first mechanism (branch field disabled, gh argv), and the
// GitLab init-then-create path where a forge failure still registers the
// local repo with a warning.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/storage/connection_store.dart';
import 'package:remote_magic_git/core/storage/saved_connection.dart';
import 'package:remote_magic_git/features/workspace/create_repo_sheet.dart';

class _FakeExecutor extends SSHCommandExecutor {
  final List<List<String>> calls = [];
  final List<SSHCommandResult> results = [];

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
  }) async {
    calls.add(gitArgs);
    return results.isNotEmpty
        ? results.removeAt(0)
        : const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }
}

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
        home: CreateRepositorySheet.connected(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (stub, exec, store);
}

Finder _createButton() => find.widgetWithText(PushButton, 'Create');

Finder _nameField() => find.byWidgetPredicate(
  (w) => w is MacosTextField && w.placeholder == 'my-project',
);

void main() {
  testWidgets('Create is disabled until a valid name exists', (tester) async {
    await _pumpConnected(tester);
    expect(tester.widget<PushButton>(_createButton()).onPressed, isNull);

    await tester.enterText(_nameField(), 'new-proj');
    await tester.pumpAndSettle();
    expect(tester.widget<PushButton>(_createButton()).onPressed, isNotNull);

    await tester.enterText(_nameField(), '../evil');
    await tester.pumpAndSettle();
    expect(tester.widget<PushButton>(_createButton()).onPressed, isNull);
  });

  testWidgets('plain create: git init -b main in the parent, then activates', (
    tester,
  ) async {
    final (stub, exec, store) = await _pumpConnected(tester);
    await tester.enterText(_nameField(), 'new-proj');
    await tester.pumpAndSettle();

    exec.results.add(_ok('absent')); // probe
    await tester.tap(_createButton());
    await tester.pumpAndSettle();

    expect(exec.calls.last, ['git', 'init', '-b', 'main', '--', 'new-proj']);
    expect(stub.repoPathsSet, ['/srv/new-proj']);
    expect(store.updated.single.allRepoPaths, contains('/srv/new-proj'));
    expect(find.byType(CreateRepositorySheet), findsNothing, reason: 'popped');
  });

  testWidgets('an existing destination fails with a clear error', (
    tester,
  ) async {
    final (stub, exec, _) = await _pumpConnected(tester);
    await tester.enterText(_nameField(), 'new-proj');
    await tester.pumpAndSettle();

    exec.results.add(_ok('exists')); // probe
    await tester.tap(_createButton());
    await tester.pumpAndSettle();

    expect(find.textContaining('already exists'), findsOneWidget);
    expect(stub.repoPathsSet, isEmpty);
    expect(
      exec.calls.every((c) => c.first != 'git'),
      isTrue,
      reason: 'no init issued',
    );
  });

  testWidgets(
    'GitHub mode disables the branch field and uses gh repo create --clone',
    (tester) async {
      final (stub, exec, _) = await _pumpConnected(tester);
      await tester.enterText(_nameField(), 'new-proj');
      await tester.pumpAndSettle();

      // Enable the forge section (GitHub is the default forge).
      await tester.tap(
        find.byWidgetPredicate(
          (w) =>
              w is MacosTooltip &&
              w.message.startsWith('Also create on GitHub'),
        ),
      );
      await tester.pumpAndSettle();

      final branchField = tester.widget<MacosTextField>(
        find.byWidgetPredicate(
          (w) => w is MacosTextField && w.placeholder == 'main',
        ),
      );
      expect(branchField.enabled, isFalse, reason: 'forge default governs');

      exec.results.add(_ok('absent')); // probe
      await tester.tap(_createButton());
      await tester.pumpAndSettle();

      expect(exec.calls.last, [
        'gh',
        'repo',
        'create',
        'new-proj',
        '--private',
        '--clone',
      ]);
      expect(stub.repoPathsSet, ['/srv/new-proj']);
      expect(find.byType(CreateRepositorySheet), findsNothing);
    },
  );

  testWidgets(
    'GitLab mode inits first; a failed forge publish still registers the '
    'repo and shows a warning',
    (tester) async {
      final (stub, exec, _) = await _pumpConnected(tester);
      await tester.enterText(_nameField(), 'new-proj');
      await tester.pumpAndSettle();

      await tester.tap(
        find.byWidgetPredicate(
          (w) =>
              w is MacosTooltip &&
              w.message.startsWith('Also create on GitHub'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(PushButton, 'GitLab'));
      await tester.pumpAndSettle();

      exec.results.add(_ok('absent')); // probe
      exec.results.add(_ok('')); // git init succeeds
      exec.results.add(
        const SSHCommandResult(
          exitCode: 1,
          stdout: '',
          stderr: '401 unauthorized',
        ),
      ); // glab repo create fails
      await tester.tap(_createButton());
      await tester.pumpAndSettle();

      expect(
        exec.calls.map((c) => c.take(2).join(' ')),
        containsAllInOrder(['git init', 'glab repo']),
      );
      expect(stub.repoPathsSet, ['/srv/new-proj'],
          reason: 'local repo registered despite forge failure');
      expect(find.byType(CreateRepositorySheet), findsOneWidget,
          reason: 'stays open to show the warning');
      expect(find.textContaining('publishing to GitLab failed'), findsOneWidget);

      await tester.tap(find.widgetWithText(PushButton, 'Close'));
      await tester.pumpAndSettle();
      expect(find.byType(CreateRepositorySheet), findsNothing);
    },
  );
}
