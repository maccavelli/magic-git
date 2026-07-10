// CreateRepositorySheet: submit gating, plain git init argv + registration,
// the GitHub forge-first mechanism (branch field disabled, gh argv), the
// GitLab init-then-create path where a forge failure still registers the
// local repo with a warning, the custom-URL mode (init + git remote add),
// and the post-create origin verification shared by all remote modes.

import 'dart:convert';
import 'dart:typed_data';

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
import 'package:remote_magic_git/features/workspace/create_repo_sheet.dart';

class _FakeExecutor extends SSHCommandExecutor {
  final List<List<String>> calls = [];
  final List<SSHCommandResult> results = [];
  final Map<String, String> uploads = {};

  _FakeExecutor() : super(SSHClientManager());

  @override
  Future<void> uploadBytes(String remotePath, Uint8List bytes) async {
    uploads[remotePath] = utf8.decode(bytes);
  }

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

Finder _continueButton() => find.widgetWithText(PushButton, 'Continue');

Finder _nameField() => find.byWidgetPredicate(
  (w) => w is MacosTextField && w.placeholder == 'my-project',
);

/// Advances the wizard one step (the current step must be valid).
Future<void> _next(WidgetTester tester) async {
  await tester.tap(_continueButton());
  await tester.pumpAndSettle();
}

void main() {
  // Don't wait out the green-bar flash before the success pop.
  CreateRepositorySheet.successPopDelay = Duration.zero;

  testWidgets('the Details step gates Continue until a valid name exists', (
    tester,
  ) async {
    await _pumpConnected(tester);
    await _next(tester); // Source → Remote (parent prefilled from session)
    await _next(tester); // Remote → Details (default: no remote)

    expect(tester.widget<PushButton>(_continueButton()).onPressed, isNull);

    await tester.enterText(_nameField(), 'new-proj');
    await tester.pumpAndSettle();
    expect(tester.widget<PushButton>(_continueButton()).onPressed, isNotNull);

    await tester.enterText(_nameField(), '../evil');
    await tester.pumpAndSettle();
    expect(tester.widget<PushButton>(_continueButton()).onPressed, isNull);
  });

  testWidgets(
    'the forge host prefills from the CLI sign-in, but never overwrites a '
    'typed host',
    (tester) async {
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
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            connectionProvider.overrideWith(() => stub),
            activeExecutorProvider.overrideWithValue(_FakeExecutor()),
            connectionStoreProvider.overrideWithValue(_FakeStore()),
            savedConnectionsProvider.overrideWith((ref) async => [_conn]),
            gitServiceProvider.overrideWithValue(GitService(_FakeExecutor())),
            forgeAuthHostProvider.overrideWith(
              (ref, key) async =>
                  key.$1 == Forge.gitlab ? 'gitlab.lkqdev.com' : null,
            ),
          ],
          child: const MacosApp(
            debugShowCheckedModeBanner: false,
            home: CreateRepositorySheet.connected(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _next(tester); // Source → Remote

      await tester.tap(find.widgetWithText(PushButton, 'GitLab'));
      await tester.pumpAndSettle();

      Finder hostField() => find.byWidgetPredicate(
        (w) => w is MacosTextField && w.controller?.text != '',
      );
      expect(find.text('gitlab.lkqdev.com'), findsOneWidget,
          reason: 'stock default replaced by the CLI sign-in host');
      expect(hostField(), findsWidgets);

      // A user-typed host survives switching forges and re-resolution.
      await tester.enterText(
        find.byWidgetPredicate(
          (w) =>
              w is MacosTextField && w.controller?.text == 'gitlab.lkqdev.com',
        ),
        'gitlab.other.example',
      );
      await tester.pumpAndSettle();
      expect(find.text('gitlab.other.example'), findsOneWidget);
      expect(find.text('gitlab.lkqdev.com'), findsNothing,
          reason: 'typed host was not overwritten by the prefill');
    },
  );

  testWidgets('the progress bar tracks the current step left to right', (
    tester,
  ) async {
    await _pumpConnected(tester);
    expect(find.text('Step 1 of 4 — Source'), findsOneWidget);
    await _next(tester);
    expect(find.text('Step 2 of 4 — Remote'), findsOneWidget);
    await _next(tester);
    expect(find.text('Step 3 of 4 — Details'), findsOneWidget);
  });

  testWidgets('plain create: git init -b main in the parent, then activates', (
    tester,
  ) async {
    final (stub, exec, store) = await _pumpConnected(tester);
    await _next(tester); // Source
    await _next(tester); // Remote (None)
    await tester.enterText(_nameField(), 'new-proj');
    await tester.pumpAndSettle();
    await _next(tester); // Details → Review

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
    await _next(tester); // Source
    await _next(tester); // Remote (None)
    await tester.enterText(_nameField(), 'new-proj');
    await tester.pumpAndSettle();
    await _next(tester); // Details → Review

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
    'GitHub mode inits on the chosen branch, publishes with --source, '
    'and verifies origin afterwards',
    (tester) async {
      final (stub, exec, _) = await _pumpConnected(tester);
      await _next(tester); // Source
      await tester.tap(find.widgetWithText(PushButton, 'GitHub'));
      await tester.pumpAndSettle();
      await _next(tester); // Remote → Details
      await tester.enterText(_nameField(), 'new-proj');
      await tester.pumpAndSettle();

      final branchField = tester.widget<MacosTextField>(
        find.byWidgetPredicate(
          (w) => w is MacosTextField && w.placeholder == 'main',
        ),
      );
      expect(branchField.enabled, isNot(isFalse),
          reason: 'init-first: the user branch is authoritative');
      await _next(tester); // Details → Review

      exec.results.add(_ok('absent')); // probe
      exec.results.add(_ok('')); // git init
      exec.results.add(_ok('')); // gh repo create --source
      exec.results.add(_ok('git@github.com:me/new-proj.git\n')); // verify
      await tester.tap(_createButton());
      await tester.pumpAndSettle();

      expect(
        exec.calls.map((c) => c.join(' ')),
        containsAllInOrder([
          'git init -b main -- new-proj',
          'gh repo create new-proj --private --source . --remote origin',
          'git remote get-url origin',
        ]),
        reason: 'no --push without a commit; origin verified at the end',
      );
      expect(stub.repoPathsSet, ['/srv/new-proj']);
      expect(find.byType(CreateRepositorySheet), findsNothing);
    },
  );

  testWidgets(
    'the README option commits before the GitHub publish and adds --push',
    (tester) async {
      final (stub, exec, _) = await _pumpConnected(tester);
      await _next(tester); // Source
      await tester.tap(find.widgetWithText(PushButton, 'GitHub'));
      await tester.pumpAndSettle();
      await _next(tester); // Remote → Details
      await tester.enterText(_nameField(), 'new-proj');
      await tester.pumpAndSettle();
      await tester.tap(
        find.byWidgetPredicate(
          (w) =>
              w is MacosTooltip && w.message.startsWith('Add a README'),
        ),
      );
      await tester.pumpAndSettle();
      await _next(tester); // Details → Review

      exec.results.add(_ok('absent')); // probe
      exec.results.add(_ok('')); // git init
      exec.results.add(_ok('')); // git add
      exec.results.add(_ok('')); // git commit
      exec.results.add(_ok('')); // gh repo create --source --push
      exec.results.add(_ok('git@github.com:me/new-proj.git\n')); // verify
      await tester.tap(_createButton());
      await tester.pumpAndSettle();

      expect(exec.uploads['/srv/new-proj/README.md'], '# new-proj\n');
      expect(
        exec.calls.map((c) => c.join(' ')),
        containsAllInOrder([
          'git init -b main -- new-proj',
          'git add -- README.md',
          'git commit -m Initial commit',
          'gh repo create new-proj --private --source . --remote origin '
              '--push',
          'git remote get-url origin',
        ]),
      );
      expect(stub.repoPathsSet, ['/srv/new-proj']);
      expect(find.byType(CreateRepositorySheet), findsNothing);
    },
  );

  testWidgets(
    'GitLab mode inits first; a failed forge publish still registers the '
    'repo and shows a warning',
    (tester) async {
      final (stub, exec, _) = await _pumpConnected(tester);
      await _next(tester); // Source
      await tester.tap(find.widgetWithText(PushButton, 'GitLab'));
      await tester.pumpAndSettle();
      await _next(tester); // Remote → Details
      await tester.enterText(_nameField(), 'new-proj');
      await tester.pumpAndSettle();
      await _next(tester); // Details → Review

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
      expect(
        exec.calls.map((c) => c.join(' ')),
        isNot(contains('git remote get-url origin')),
        reason: 'a failed publish already warns — no redundant verification',
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

  testWidgets(
    'GitLab mode with a README pushes the initial commit with -u',
    (tester) async {
      final (stub, exec, _) = await _pumpConnected(tester);
      await _next(tester); // Source
      await tester.tap(find.widgetWithText(PushButton, 'GitLab'));
      await tester.pumpAndSettle();
      await _next(tester); // Remote → Details
      await tester.enterText(_nameField(), 'new-proj');
      await tester.pumpAndSettle();
      await tester.tap(
        find.byWidgetPredicate(
          (w) =>
              w is MacosTooltip && w.message.startsWith('Add a README'),
        ),
      );
      await tester.pumpAndSettle();
      await _next(tester); // Details → Review

      exec.results.add(_ok('absent')); // probe
      exec.results.add(_ok('')); // git init
      exec.results.add(_ok('')); // git add
      exec.results.add(_ok('')); // git commit
      exec.results.add(_ok('')); // glab repo create
      exec.results.add(_ok('')); // git push -u
      exec.results.add(_ok('git@gitlab.com:me/new-proj.git\n')); // verify
      await tester.tap(_createButton());
      await tester.pumpAndSettle();

      expect(
        exec.calls.map((c) => c.join(' ')),
        containsAllInOrder([
          'git init -b main -- new-proj',
          'git commit -m Initial commit',
          'glab repo create new-proj --private',
          'git push -u origin main',
          'git remote get-url origin',
        ]),
      );
      expect(stub.repoPathsSet, ['/srv/new-proj']);
      expect(find.byType(CreateRepositorySheet), findsNothing);
    },
  );

  testWidgets(
    'Custom URL mode gates on a URL, then inits, wires origin, and verifies',
    (tester) async {
      final (stub, exec, _) = await _pumpConnected(tester);
      await _next(tester); // Source
      await tester.tap(find.widgetWithText(PushButton, 'Custom URL'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<PushButton>(_continueButton()).onPressed,
        isNull,
        reason: 'no URL entered yet',
      );

      const url = 'https://gitlab.example.com/me/new-proj.git';
      await tester.enterText(
        find.byWidgetPredicate(
          (w) =>
              w is MacosTextField &&
              (w.placeholder?.startsWith('git@host:') ?? false),
        ),
        url,
      );
      await tester.pumpAndSettle();
      await _next(tester); // Remote → Details
      await tester.enterText(_nameField(), 'new-proj');
      await tester.pumpAndSettle();
      await _next(tester); // Details → Review

      exec.results.add(_ok('absent')); // probe
      exec.results.add(_ok('')); // git init
      exec.results.add(_ok('')); // git remote add
      exec.results.add(_ok('$url\n')); // verify
      await tester.tap(_createButton());
      await tester.pumpAndSettle();

      expect(
        exec.calls,
        containsAllInOrder([
          ['git', 'init', '-b', 'main', '--', 'new-proj'],
          ['git', 'remote', 'add', 'origin', url],
          ['git', 'remote', 'get-url', 'origin'],
        ]),
      );
      expect(stub.repoPathsSet, ['/srv/new-proj']);
      expect(find.byType(CreateRepositorySheet), findsNothing);
    },
  );

  testWidgets(
    'a create whose origin verification fails still registers the repo but '
    'stays open with a warning',
    (tester) async {
      final (stub, exec, _) = await _pumpConnected(tester);
      await _next(tester); // Source
      await tester.tap(find.widgetWithText(PushButton, 'GitHub'));
      await tester.pumpAndSettle();
      await _next(tester); // Remote → Details
      await tester.enterText(_nameField(), 'new-proj');
      await tester.pumpAndSettle();
      await _next(tester); // Details → Review

      exec.results.add(_ok('absent')); // probe
      exec.results.add(_ok('')); // git init
      exec.results.add(_ok('')); // gh repo create --source
      exec.results.add(
        const SSHCommandResult(
          exitCode: 2,
          stdout: '',
          stderr: "error: No such remote 'origin'",
        ),
      ); // verify fails
      await tester.tap(_createButton());
      await tester.pumpAndSettle();

      expect(stub.repoPathsSet, ['/srv/new-proj'],
          reason: 'repo is kept and registered');
      expect(find.byType(CreateRepositorySheet), findsOneWidget,
          reason: 'stays open to show the warning');
      expect(
        find.textContaining('no "origin" remote is configured'),
        findsOneWidget,
      );
    },
  );

  // --- Existing-folder source -----------------------------------------

  Future<void> toExistingFolder(WidgetTester tester, String path) async {
    await tester.tap(find.widgetWithText(PushButton, 'Existing folder'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byWidgetPredicate(
        (w) => w is MacosTextField && w.placeholder == '/srv/app',
      ),
      path,
    );
    await tester.pumpAndSettle();
  }

  const notARepo = SSHCommandResult(
    exitCode: 128,
    stdout: '',
    stderr: 'fatal: not a git repository (or any of the parent '
        'directories): .git',
  );
  const noOrigin = SSHCommandResult(
    exitCode: 2,
    stdout: '',
    stderr: "error: No such remote 'origin'",
  );
  const unbornHead = SSHCommandResult(exitCode: 1, stdout: '', stderr: '');

  testWidgets(
    'existing folder that is not a repo yet: init in place, publish to '
    'GitHub without --push',
    (tester) async {
      final (stub, exec, _) = await _pumpConnected(tester);
      await toExistingFolder(tester, '/srv/app');
      await _next(tester); // Source
      await tester.tap(find.widgetWithText(PushButton, 'GitHub'));
      await tester.pumpAndSettle();
      await _next(tester); // Remote → Details
      await tester.enterText(_nameField(), 'app-repo');
      await tester.pumpAndSettle();
      await _next(tester); // Details → Review

      exec.results.add(notARepo); // classify: not a repo
      exec.results.add(_ok('')); // git init (in place)
      exec.results.add(unbornHead); // HEAD doesn't resolve — nothing to push
      exec.results.add(_ok('')); // gh repo create --source
      exec.results.add(_ok('git@github.com:me/app-repo.git\n')); // verify
      await tester.tap(_createButton());
      await tester.pumpAndSettle();

      expect(
        exec.calls.map((c) => c.join(' ')),
        containsAllInOrder([
          'git rev-parse --show-toplevel',
          'git init -b main',
          'git rev-parse --verify --quiet HEAD',
          'gh repo create app-repo --private --source . --remote origin',
          'git remote get-url origin',
        ]),
      );
      expect(stub.repoPathsSet, ['/srv/app'],
          reason: 'the folder itself becomes the workspace');
      expect(find.byType(CreateRepositorySheet), findsNothing);
    },
  );

  testWidgets(
    'existing repo with history: init skipped, existing commits pushed '
    'with gh --push',
    (tester) async {
      final (stub, exec, _) = await _pumpConnected(tester);
      await toExistingFolder(tester, '/srv/app');
      await _next(tester); // Source
      await tester.tap(find.widgetWithText(PushButton, 'GitHub'));
      await tester.pumpAndSettle();
      await _next(tester); // Remote → Details
      await tester.enterText(_nameField(), 'app-repo');
      await tester.pumpAndSettle();
      await _next(tester); // Details → Review

      exec.results.add(_ok('/srv/app\n')); // classify: repo root
      exec.results.add(noOrigin); // origin guard: nothing wired yet
      exec.results.add(_ok('abc123\n')); // HEAD resolves — history exists
      exec.results.add(_ok('')); // gh repo create --source --push
      exec.results.add(_ok('git@github.com:me/app-repo.git\n')); // verify
      await tester.tap(_createButton());
      await tester.pumpAndSettle();

      expect(
        exec.calls.map((c) => c.join(' ')),
        contains(
          'gh repo create app-repo --private --source . --remote origin '
          '--push',
        ),
      );
      expect(
        exec.calls.map((c) => c.take(2).join(' ')),
        isNot(contains('git init')),
        reason: 'already a repository — never re-inited',
      );
      expect(stub.repoPathsSet, ['/srv/app']);
      expect(find.byType(CreateRepositorySheet), findsNothing);
    },
  );

  testWidgets(
    'an existing origin blocks the publish until "Replace existing origin" '
    'is enabled, then gets removed and rewired',
    (tester) async {
      final (stub, exec, _) = await _pumpConnected(tester);
      await toExistingFolder(tester, '/srv/app');
      await _next(tester); // Source
      await tester.tap(find.widgetWithText(PushButton, 'GitHub'));
      await tester.pumpAndSettle();
      await _next(tester); // Remote → Details
      await tester.enterText(_nameField(), 'app-repo');
      await tester.pumpAndSettle();
      await _next(tester); // Details → Review

      exec.results.add(_ok('/srv/app\n')); // classify: repo root
      exec.results.add(_ok('git@old-host:me/app.git\n')); // origin exists
      await tester.tap(_createButton());
      await tester.pumpAndSettle();

      expect(
        find.textContaining('already has an origin remote'),
        findsOneWidget,
      );
      expect(stub.repoPathsSet, isEmpty, reason: 'nothing was touched');
      expect(find.byType(CreateRepositorySheet), findsOneWidget);

      // Go back to the Remote step, opt in, and retry.
      await tester.tap(find.widgetWithText(PushButton, 'Back'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(PushButton, 'Back'));
      await tester.pumpAndSettle();
      final replaceToggle = find.byWidgetPredicate(
        (w) =>
            w is MacosTooltip &&
            w.message.startsWith('Replace existing origin'),
      );
      await tester.ensureVisible(replaceToggle);
      await tester.pumpAndSettle();
      await tester.tap(replaceToggle);
      await tester.pumpAndSettle();
      await _next(tester); // Remote → Details
      await _next(tester); // Details → Review

      exec.results.add(_ok('/srv/app\n')); // classify: repo root
      exec.results.add(_ok('git@old-host:me/app.git\n')); // origin exists
      exec.results.add(_ok('')); // git remote remove origin
      exec.results.add(_ok('abc123\n')); // HEAD resolves
      exec.results.add(_ok('')); // gh repo create --source --push
      exec.results.add(_ok('git@github.com:me/app-repo.git\n')); // verify
      await tester.tap(_createButton());
      await tester.pumpAndSettle();

      expect(
        exec.calls.map((c) => c.join(' ')),
        contains('git remote remove origin'),
      );
      expect(stub.repoPathsSet, ['/srv/app']);
      expect(find.byType(CreateRepositorySheet), findsNothing);
    },
  );

  testWidgets('a folder nested inside another repo is refused', (
    tester,
  ) async {
    final (stub, exec, _) = await _pumpConnected(tester);
    await toExistingFolder(tester, '/srv/app');
    await _next(tester); // Source
    await tester.tap(find.widgetWithText(PushButton, 'GitHub'));
    await tester.pumpAndSettle();
    await _next(tester); // Remote → Details
    await tester.enterText(_nameField(), 'app-repo');
    await tester.pumpAndSettle();
    await _next(tester); // Details → Review

    exec.results.add(_ok('/srv\n')); // classify: toplevel is a parent
    await tester.tap(_createButton());
    await tester.pumpAndSettle();

    expect(
      find.textContaining('inside another Git repository'),
      findsOneWidget,
    );
    expect(stub.repoPathsSet, isEmpty);
    expect(find.byType(CreateRepositorySheet), findsOneWidget);
  });

  testWidgets(
    'existing folder + commit-all + custom URL: contents committed, origin '
    'wired, and HEAD pushed with -u',
    (tester) async {
      final (stub, exec, _) = await _pumpConnected(tester);
      await toExistingFolder(tester, '/srv/app');
      await _next(tester); // Source
      await tester.tap(find.widgetWithText(PushButton, 'Custom URL'));
      await tester.pumpAndSettle();
      const url = 'git@gitea.example.com:me/app.git';
      await tester.enterText(
        find.byWidgetPredicate(
          (w) =>
              w is MacosTextField &&
              (w.placeholder?.startsWith('git@host:') ?? false),
        ),
        url,
      );
      await tester.pumpAndSettle();
      await _next(tester); // Remote → Details
      await tester.tap(
        find.byWidgetPredicate(
          (w) =>
              w is MacosTooltip &&
              w.message.startsWith('Commit all existing contents'),
        ),
      );
      await tester.pumpAndSettle();
      await _next(tester); // Details → Review

      exec.results.add(notARepo); // classify: not a repo
      exec.results.add(_ok('')); // git init (in place)
      exec.results.add(_ok('')); // git add --all
      exec.results.add(_ok('')); // git commit
      exec.results.add(_ok('')); // git remote add
      exec.results.add(_ok('')); // git push -u origin HEAD
      exec.results.add(_ok('$url\n')); // verify
      await tester.tap(_createButton());
      await tester.pumpAndSettle();

      expect(
        exec.calls.map((c) => c.join(' ')),
        containsAllInOrder([
          'git init -b main',
          'git add --all',
          'git commit -m Initial commit',
          'git remote add origin $url',
          'git push -u origin HEAD',
          'git remote get-url origin',
        ]),
      );
      expect(stub.repoPathsSet, ['/srv/app']);
      expect(find.byType(CreateRepositorySheet), findsNothing);
    },
  );
}
