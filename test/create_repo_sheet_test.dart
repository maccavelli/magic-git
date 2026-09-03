// CreateRepositorySheet: submit gating, plain git init argv + registration,
// git identity (local user.name/user.email + authored initial commit),
// the GitHub forge-first mechanism (branch field disabled, gh argv), the
// GitLab init-then-create path where a forge failure still registers the
// local repo with a warning, the custom-URL mode (init + git remote add),
// and the post-create origin verification shared by all remote modes.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/forge/forge.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/settings/app_settings.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/storage/connection_store.dart';
import 'package:remote_magic_git/core/storage/saved_connection.dart';
import 'package:remote_magic_git/features/common/buttons.dart';
import 'package:remote_magic_git/features/common/field_styles.dart';
import 'package:remote_magic_git/features/workspace/create_repo_sheet.dart';
import 'package:riverpod/misc.dart' show Override;

import 'helpers/app_scope.dart';

class _FakeExecutor extends SSHCommandExecutor {
  final List<List<String>> calls = [];
  final List<SSHCommandResult> results = [];
  final Map<String, String> uploads = {};

  /// When set, every execute parks on it — lets a test hold the create
  /// "in flight" to prove Escape can't tear the session down mid-run.
  Completer<void>? gate;

  _FakeExecutor() : super(SSHClientManager());

  @override
  Future<void> uploadBytes(
    String remotePath,
    Uint8List bytes, {
    String? routingRepo,
  }) async {
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
    Duration? activityIdle,
    OperationDescriptor? operation,
    OperationEventCallback? onOperationEvent,
    CommandOutputCallback? onOutput,
  }) async {
    calls.add(gitArgs);
    if (gate != null) await gate!.future;
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

class _PrefillSettings extends AppSettingsNotifier {
  @override
  AppSettings build() => const AppSettings(
    committerName: 'Jane Developer',
    committerEmail: 'jane@example.com',
  );
}

/// Starts empty (the real notifier's first frame) then can publish a stored
/// identity, matching Settings' async disk load.
class _LateSettings extends AppSettingsNotifier {
  @override
  AppSettings build() => const AppSettings();

  void arrive({
    String committerName = 'Jane Developer',
    String committerEmail = 'jane@example.com',
  }) {
    state = AppSettings(
      committerName: committerName,
      committerEmail: committerEmail,
    );
  }
}

/// Counts [setPreferences] calls so a create cannot silently write identity
/// into Settings (empty there is intentional).
class _GuardSettings extends AppSettingsNotifier {
  int preferenceWrites = 0;

  @override
  AppSettings build() => const AppSettings();

  @override
  Future<void> setPreferences({
    String? committerName,
    String? committerEmail,
    PullMode? defaultPullMode,
    bool? pushFollowTags,
    int? autoFetchMinutes,
  }) async {
    preferenceWrites++;
  }
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
  WidgetTester tester, {
  List<Override> extraOverrides = const [],
}) async {
  // Room for the wizard + completed-warning footer (cloneUrl failure copy
  // can be long; a tight surface overflows the step breadcrumb).
  await tester.binding.setSurfaceSize(const Size(1200, 900));
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
    appProviderScope(
      overrides: [
        connectionProvider.overrideWith(() => stub),
        activeExecutorProvider.overrideWithValue(exec),
        connectionStoreProvider.overrideWithValue(store),
        savedConnectionsProvider.overrideWith((ref) async => [_conn]),
        gitServiceProvider.overrideWithValue(GitService(_FakeExecutor())),
        ...extraOverrides,
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

/// Advances fake time past [GhService.cloneUrl]/[GlabService.cloneUrl] retries.
Future<void> _pumpCreate(WidgetTester tester) async {
  await tester.tap(_createButton());
  await tester.pump();
  // Retries use 250ms + 500ms delays when lookup fails.
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pumpAndSettle();
  // Long completed-warning banners can overflow tight step chrome in tests;
  // drain those non-fatal layout exceptions so the behavioral asserts run.
  // ignore: invalid_use_of_protected_member
  while (tester.takeException() != null) {}
}

Finder _createButton() => find.widgetWithText(AppPushButton, 'Create');

Finder _continueButton() => find.widgetWithText(AppPushButton, 'Continue');

Finder _nameField() => find.byWidgetPredicate(
  (w) => w is MacosTextField && w.placeholder == 'my-project',
);

Finder _authorNameField() => find.byWidgetPredicate(
  (w) => w is MacosTextField && w.placeholder == 'Your name',
);

Finder _authorEmailField() => find.byWidgetPredicate(
  (w) => w is MacosTextField && w.placeholder == 'you@example.com',
);

const _testAuthorName = 'Ada Lovelace';
const _testAuthorEmail = 'ada@example.com';

/// Fills the Details-step identity fields. Required when an initial
/// commit is on (README / commit-all); optional otherwise.
Future<void> _fillIdentity(WidgetTester tester) async {
  await tester.ensureVisible(_authorNameField());
  await tester.pumpAndSettle();
  await tester.enterText(_authorNameField(), _testAuthorName);
  await tester.enterText(_authorEmailField(), _testAuthorEmail);
  await tester.pumpAndSettle();
}

Finder _readmeToggle() => find.byWidgetPredicate(
  (w) => w is MacosTooltip && w.message.startsWith('Add a README'),
);

Future<void> _tapReadme(WidgetTester tester) async {
  await tester.ensureVisible(_readmeToggle());
  await tester.pumpAndSettle();
  await tester.tap(_readmeToggle());
  await tester.pumpAndSettle();
}

/// Queues the two local `git config` writes that follow init when identity
/// is filled.
void _queueIdentityConfig(_FakeExecutor exec) {
  exec.results.add(_ok('')); // git config --local user.name
  exec.results.add(_ok('')); // git config --local user.email
}

String get _identityCommit =>
    'git -c user.name=$_testAuthorName -c user.email=$_testAuthorEmail '
    'commit --no-gpg-sign -m Initial commit';

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

    expect(tester.widget<AppPushButton>(_continueButton()).onPressed, isNull);

    await tester.enterText(_nameField(), 'new-proj');
    await tester.pumpAndSettle();
    expect(
      tester.widget<AppPushButton>(_continueButton()).onPressed,
      isNotNull,
    );

    await tester.enterText(_nameField(), '../evil');
    await tester.pumpAndSettle();
    expect(tester.widget<AppPushButton>(_continueButton()).onPressed, isNull);
  });

  testWidgets('Add a README gates Continue until a git identity is filled', (
    tester,
  ) async {
    await _pumpConnected(tester);
    await _next(tester); // Source
    await _next(tester); // Remote
    await tester.enterText(_nameField(), 'new-proj');
    await tester.pumpAndSettle();
    expect(
      tester.widget<AppPushButton>(_continueButton()).onPressed,
      isNotNull,
      reason: 'identity is optional until an initial commit is on',
    );
    expect(
      tester.widget<MacosTextField>(_authorNameField()).decoration,
      kAppTextFieldDecoration,
      reason: 'optional identity is not outlined as an error',
    );
    expect(
      tester.widget<MacosTextField>(_authorEmailField()).decoration,
      kAppTextFieldDecoration,
    );

    await _tapReadme(tester);
    expect(
      tester.widget<AppPushButton>(_continueButton()).onPressed,
      isNull,
      reason: 'README commit requires name + email',
    );
    expect(
      tester.widget<MacosTextField>(_authorNameField()).decoration,
      kAppTextFieldErrorDecoration,
      reason: 'required empty name is outlined in red',
    );
    expect(
      tester.widget<MacosTextField>(_authorEmailField()).decoration,
      kAppTextFieldErrorDecoration,
      reason: 'required empty email is outlined in red',
    );

    await tester.enterText(_authorNameField(), _testAuthorName);
    await tester.pumpAndSettle();
    expect(
      tester.widget<AppPushButton>(_continueButton()).onPressed,
      isNull,
      reason: 'email still missing',
    );
    expect(
      tester.widget<MacosTextField>(_authorNameField()).decoration,
      kAppTextFieldDecoration,
      reason: 'a filled name drops the error outline',
    );
    expect(
      tester.widget<MacosTextField>(_authorEmailField()).decoration,
      kAppTextFieldErrorDecoration,
    );

    await tester.enterText(_authorEmailField(), 'not-an-email');
    await tester.pumpAndSettle();
    expect(
      tester.widget<AppPushButton>(_continueButton()).onPressed,
      isNull,
      reason: 'email must contain an @ with both sides',
    );
    expect(
      tester.widget<MacosTextField>(_authorEmailField()).decoration,
      kAppTextFieldErrorDecoration,
      reason: 'an implausible email stays outlined',
    );

    await tester.enterText(_authorEmailField(), '@x');
    await tester.pumpAndSettle();
    expect(
      tester.widget<AppPushButton>(_continueButton()).onPressed,
      isNull,
      reason: 'email must have a local part before @',
    );
    expect(
      tester.widget<MacosTextField>(_authorEmailField()).decoration,
      kAppTextFieldErrorDecoration,
    );

    await tester.enterText(_authorEmailField(), 'x@');
    await tester.pumpAndSettle();
    expect(
      tester.widget<AppPushButton>(_continueButton()).onPressed,
      isNull,
      reason: 'email must have a domain after @',
    );
    expect(
      tester.widget<MacosTextField>(_authorEmailField()).decoration,
      kAppTextFieldErrorDecoration,
    );

    await tester.enterText(_authorEmailField(), _testAuthorEmail);
    await tester.pumpAndSettle();
    expect(
      tester.widget<AppPushButton>(_continueButton()).onPressed,
      isNotNull,
    );
    expect(
      tester.widget<MacosTextField>(_authorNameField()).decoration,
      kAppTextFieldDecoration,
    );
    expect(
      tester.widget<MacosTextField>(_authorEmailField()).decoration,
      kAppTextFieldDecoration,
    );
  });

  testWidgets('git identity prefills from Settings', (tester) async {
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
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    await tester.pumpWidget(
      appProviderScope(
        overrides: [
          connectionProvider.overrideWith(() => stub),
          activeExecutorProvider.overrideWithValue(_FakeExecutor()),
          connectionStoreProvider.overrideWithValue(_FakeStore()),
          savedConnectionsProvider.overrideWith((ref) async => [_conn]),
          gitServiceProvider.overrideWithValue(GitService(_FakeExecutor())),
          appSettingsProvider.overrideWith(_PrefillSettings.new),
        ],
        child: const MacosApp(
          debugShowCheckedModeBanner: false,
          home: CreateRepositorySheet.connected(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _next(tester); // Source
    await _next(tester); // Remote
    expect(
      tester.widget<MacosTextField>(_authorNameField()).controller?.text,
      'Jane Developer',
    );
    expect(
      tester.widget<MacosTextField>(_authorEmailField()).controller?.text,
      'jane@example.com',
    );
  });

  testWidgets(
    'Settings-prefilled identity is not marked required when README is on',
    (tester) async {
      await _pumpConnected(
        tester,
        extraOverrides: [
          appSettingsProvider.overrideWith(_PrefillSettings.new),
        ],
      );
      await _next(tester); // Source
      await _next(tester); // Remote
      await tester.enterText(_nameField(), 'new-proj');
      await tester.pumpAndSettle();
      await _tapReadme(tester);

      expect(
        tester.widget<AppPushButton>(_continueButton()).onPressed,
        isNotNull,
        reason: 'prefilled name+email already satisfy the commit identity',
      );
      expect(
        tester.widget<MacosTextField>(_authorNameField()).decoration,
        kAppTextFieldDecoration,
        reason: 'a Settings-populated name must not outline as required',
      );
      expect(
        tester.widget<MacosTextField>(_authorEmailField()).decoration,
        kAppTextFieldDecoration,
        reason: 'a Settings-populated email must not outline as required',
      );
    },
  );

  testWidgets(
    'identity required outline clears when Settings loads after open',
    (tester) async {
      final settings = _LateSettings();
      await _pumpConnected(
        tester,
        extraOverrides: [appSettingsProvider.overrideWith(() => settings)],
      );
      await _next(tester); // Source
      await _next(tester); // Remote
      await tester.enterText(_nameField(), 'new-proj');
      await tester.pumpAndSettle();
      await _tapReadme(tester);

      expect(
        tester.widget<MacosTextField>(_authorNameField()).decoration,
        kAppTextFieldErrorDecoration,
        reason: 'empty identity is required while Settings is still default',
      );
      expect(tester.widget<AppPushButton>(_continueButton()).onPressed, isNull);

      settings.arrive();
      await tester.pumpAndSettle();

      expect(
        tester.widget<MacosTextField>(_authorNameField()).controller?.text,
        'Jane Developer',
      );
      expect(
        tester.widget<MacosTextField>(_authorEmailField()).controller?.text,
        'jane@example.com',
      );
      expect(
        tester.widget<MacosTextField>(_authorNameField()).decoration,
        kAppTextFieldDecoration,
      );
      expect(
        tester.widget<MacosTextField>(_authorEmailField()).decoration,
        kAppTextFieldDecoration,
      );
      expect(
        tester.widget<AppPushButton>(_continueButton()).onPressed,
        isNotNull,
        reason: 'arriving Settings identity satisfies the required gate',
      );
    },
  );

  testWidgets('Review lists the git identity', (tester) async {
    await _pumpConnected(tester);
    await _next(tester); // Source
    await _next(tester); // Remote
    await tester.enterText(_nameField(), 'new-proj');
    await tester.pumpAndSettle();
    await _fillIdentity(tester);
    await _next(tester); // Details → Review
    expect(find.text('Git identity'), findsOneWidget);
    expect(find.text('Ada Lovelace · ada@example.com'), findsOneWidget);
  });

  testWidgets('typed identity is not overwritten when Settings loads', (
    tester,
  ) async {
    final settings = _LateSettings();
    await _pumpConnected(
      tester,
      extraOverrides: [appSettingsProvider.overrideWith(() => settings)],
    );
    await _next(tester); // Source
    await _next(tester); // Remote
    await tester.enterText(_nameField(), 'new-proj');
    await tester.pumpAndSettle();
    await _fillIdentity(tester);

    settings.arrive();
    await tester.pumpAndSettle();

    expect(
      tester.widget<MacosTextField>(_authorNameField()).controller?.text,
      _testAuthorName,
      reason: 'a typed name must not snap back to Settings',
    );
    expect(
      tester.widget<MacosTextField>(_authorEmailField()).controller?.text,
      _testAuthorEmail,
      reason: 'a typed email must not snap back to Settings',
    );
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
        appProviderScope(
          overrides: [
            connectionProvider.overrideWith(() => stub),
            activeExecutorProvider.overrideWithValue(_FakeExecutor()),
            connectionStoreProvider.overrideWithValue(_FakeStore()),
            savedConnectionsProvider.overrideWith((ref) async => [_conn]),
            gitServiceProvider.overrideWithValue(GitService(_FakeExecutor())),
            forgeAuthHostProvider.overrideWith(
              (ref, key) async =>
                  key.$1 == Forge.gitlab ? 'gitlab.example.com' : null,
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

      await tester.tap(find.widgetWithText(AppPushButton, 'GitLab'));
      await tester.pumpAndSettle();

      Finder hostField() => find.byWidgetPredicate(
        (w) => w is MacosTextField && w.controller?.text != '',
      );
      expect(
        find.text('gitlab.example.com'),
        findsOneWidget,
        reason: 'stock default replaced by the CLI sign-in host',
      );
      expect(hostField(), findsWidgets);

      // A user-typed host survives switching forges and re-resolution.
      await tester.enterText(
        find.byWidgetPredicate(
          (w) =>
              w is MacosTextField && w.controller?.text == 'gitlab.example.com',
        ),
        'gitlab.other.example',
      );
      await tester.pumpAndSettle();
      expect(find.text('gitlab.other.example'), findsOneWidget);
      expect(
        find.text('gitlab.example.com'),
        findsNothing,
        reason: 'typed host was not overwritten by the prefill',
      );
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

  testWidgets(
    'a filled git identity is written into the new repo even without a README',
    (tester) async {
      final settings = _GuardSettings();
      // The spy itself must be seen to fire, or a 0-write assert is noise.
      await settings.setPreferences(
        committerName: 'should-count',
        committerEmail: 'x@y',
      );
      expect(settings.preferenceWrites, 1);
      settings.preferenceWrites = 0;

      final (stub, exec, _) = await _pumpConnected(
        tester,
        extraOverrides: [appSettingsProvider.overrideWith(() => settings)],
      );
      await _next(tester); // Source
      await _next(tester); // Remote (None)
      await tester.enterText(_nameField(), 'new-proj');
      await tester.pumpAndSettle();
      await _fillIdentity(tester);
      await _next(tester); // Details → Review

      exec.results.add(_ok('absent')); // probe
      exec.results.add(_ok('')); // git init
      _queueIdentityConfig(exec);
      await tester.tap(_createButton());
      await tester.pumpAndSettle();

      expect(
        exec.calls.map((c) => c.join(' ')),
        containsAllInOrder([
          'git init -b main -- new-proj',
          'git config --local user.name $_testAuthorName',
          'git config --local user.email $_testAuthorEmail',
        ]),
      );
      expect(stub.repoPathsSet, ['/srv/new-proj']);
      expect(find.byType(CreateRepositorySheet), findsNothing);
      expect(
        exec.calls.map((c) => c.join(' ')),
        isNot(contains(_identityCommit)),
        reason: 'README off — no initial commit',
      );
      expect(
        exec.calls.any((c) => c.take(3).join(' ') == 'git remote add'),
        isFalse,
        reason: 'Remote None — no origin',
      );
      expect(
        settings.preferenceWrites,
        0,
        reason: 'create must not write identity into Settings',
      );
    },
  );

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

  const noOrigin = SSHCommandResult(
    exitCode: 2,
    stdout: '',
    stderr: "error: No such remote 'origin'",
  );

  /// API-only create (empty stdout → no create-output URL, exercising the
  /// lookup fallback) → missing origin → protocol probe → view lookup →
  /// remote add → verify.
  void queueGithubOriginWire(
    _FakeExecutor exec, {
    required String name,
    bool push = false,
  }) {
    exec.results.add(_ok('')); // gh repo create (API only)
    exec.results.add(noOrigin); // get-url: missing
    exec.results.add(_ok('https')); // git_protocol (probed first)
    exec.results.add(
      _ok(
        '{"url":"https://github.com/me/$name","sshUrl":'
        '"git@github.com:me/$name.git"}',
      ),
    ); // gh repo view
    exec.results.add(_ok('')); // git remote add
    if (push) exec.results.add(_ok('')); // git push -u
    exec.results.add(_ok('https://github.com/me/$name.git\n')); // verify
  }

  void queueGitlabOriginWire(
    _FakeExecutor exec, {
    required String name,
    bool push = false,
  }) {
    exec.results.add(_ok('')); // glab repo create --skipGitInit
    exec.results.add(noOrigin); // get-url: missing
    exec.results.add(_ok('')); // glab config get git_protocol (unset → https)
    exec.results.add(
      _ok('HTTP/2.0 200 OK\n\n{"username":"me"}'),
    ); // glab api user
    exec.results.add(
      _ok(
        'HTTP/2.0 200 OK\n\n'
        '{"http_url_to_repo":"https://gitlab.com/me/$name.git",'
        '"ssh_url_to_repo":"git@gitlab.com:me/$name.git"}',
      ),
    ); // glab api projects
    exec.results.add(_ok('')); // git remote add
    if (push) exec.results.add(_ok('')); // git push -u
    exec.results.add(_ok('https://gitlab.com/me/$name.git\n')); // verify
  }

  testWidgets(
    'GitHub mode inits on the chosen branch, API-creates, wires origin, '
    'and verifies',
    (tester) async {
      final (stub, exec, _) = await _pumpConnected(tester);
      await _next(tester); // Source
      await tester.tap(find.widgetWithText(AppPushButton, 'GitHub'));
      await tester.pumpAndSettle();
      await _next(tester); // Remote → Details
      await tester.enterText(_nameField(), 'new-proj');
      await tester.pumpAndSettle();

      final branchField = tester.widget<MacosTextField>(
        find.byWidgetPredicate(
          (w) => w is MacosTextField && w.placeholder == 'main',
        ),
      );
      expect(
        branchField.enabled,
        isNot(isFalse),
        reason: 'init-first: the user branch is authoritative',
      );
      await _next(tester); // Details → Review

      exec.results.add(_ok('absent')); // probe
      exec.results.add(_ok('')); // git init
      queueGithubOriginWire(exec, name: 'new-proj');
      await tester.tap(_createButton());
      await tester.pumpAndSettle();

      final joined = exec.calls.map((c) => c.join(' ')).toList();
      expect(
        joined,
        containsAllInOrder([
          'git init -b main -- new-proj',
          'gh repo create new-proj --private',
          'git remote get-url origin',
          'gh repo view new-proj --json url,sshUrl',
          'git remote add origin https://github.com/me/new-proj.git',
          'git remote get-url origin',
        ]),
        reason: 'API-only create; Magic Git owns origin wiring',
      );
      expect(
        joined.any((c) => c.contains('--source') || c.contains('--remote')),
        isFalse,
        reason: 'never ask gh to nest local git ops',
      );
      expect(stub.repoPathsSet, ['/srv/new-proj']);
      expect(find.byType(CreateRepositorySheet), findsNothing);
    },
  );

  testWidgets(
    "the URL printed by gh repo create is the primary origin source — no "
    "view lookup round trip at all",
    (tester) async {
      final (stub, exec, _) = await _pumpConnected(tester);
      await _next(tester); // Source
      await tester.tap(find.widgetWithText(AppPushButton, 'GitHub'));
      await tester.pumpAndSettle();
      await _next(tester); // Remote → Details
      await tester.enterText(_nameField(), 'new-proj');
      await tester.pumpAndSettle();
      await _next(tester); // Details → Review

      exec.results.add(_ok('absent')); // probe
      exec.results.add(_ok('')); // git init
      exec.results.add(
        _ok('https://github.com/me/new-proj\n'),
      ); // gh repo create prints the new repo URL
      exec.results.add(noOrigin); // get-url: missing
      exec.results.add(_ok('https')); // git_protocol
      exec.results.add(_ok('')); // git remote add
      exec.results.add(_ok('https://github.com/me/new-proj.git\n')); // verify
      await tester.tap(_createButton());
      await tester.pumpAndSettle();

      final joined = exec.calls.map((c) => c.join(' ')).toList();
      expect(
        joined,
        contains('git remote add origin https://github.com/me/new-proj.git'),
        reason: 'origin wired from the create output alone',
      );
      expect(
        joined.any((c) => c.startsWith('gh repo view')),
        isFalse,
        reason: 'no lookup round trip when create already printed the URL',
      );
      expect(stub.repoPathsSet, ['/srv/new-proj']);
      expect(find.byType(CreateRepositorySheet), findsNothing);
    },
  );

  testWidgets(
    'the README option commits before the GitHub publish; we push with -u',
    (tester) async {
      final (stub, exec, _) = await _pumpConnected(tester);
      await _next(tester); // Source
      await tester.tap(find.widgetWithText(AppPushButton, 'GitHub'));
      await tester.pumpAndSettle();
      await _next(tester); // Remote → Details
      await tester.enterText(_nameField(), 'new-proj');
      await tester.pumpAndSettle();
      await _tapReadme(tester);
      await _fillIdentity(tester);
      await _next(tester); // Details → Review

      exec.results.add(_ok('absent')); // probe
      exec.results.add(_ok('')); // git init
      _queueIdentityConfig(exec);
      exec.results.add(_ok('')); // git add
      exec.results.add(_ok('')); // git commit
      queueGithubOriginWire(exec, name: 'new-proj', push: true);
      await tester.tap(_createButton());
      await tester.pumpAndSettle();

      expect(exec.uploads['/srv/new-proj/README.md'], '# new-proj\n');
      expect(
        exec.calls.map((c) => c.join(' ')),
        containsAllInOrder([
          'git init -b main -- new-proj',
          'git config --local user.name $_testAuthorName',
          'git config --local user.email $_testAuthorEmail',
          'git add -- README.md',
          _identityCommit,
          'gh repo create new-proj --private',
          'git remote add origin https://github.com/me/new-proj.git',
          'git -c credential.helper= -c credential.helper=!gh auth git-credential '
              'push -u origin main',
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
      await tester.tap(find.widgetWithText(AppPushButton, 'GitLab'));
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
      exec.results.add(noOrigin); // ensure: origin missing
      // cloneUrl retries fail (empty results → empty success → null)
      await _pumpCreate(tester);

      expect(
        exec.calls.map((c) => c.take(2).join(' ')),
        containsAllInOrder(['git init', 'glab repo']),
      );
      expect(
        exec.calls.map((c) => c.join(' ')),
        contains('git remote get-url origin'),
        reason: 'ensure always runs even after create failure',
      );
      expect(stub.repoPathsSet, [
        '/srv/new-proj',
      ], reason: 'local repo registered despite forge failure');
      expect(
        find.byType(CreateRepositorySheet),
        findsOneWidget,
        reason: 'stays open to show the warning',
      );
      expect(find.textContaining('publishing to GitLab failed'), findsWidgets);

      await tester.tap(find.widgetWithText(AppPushButton, 'Close'));
      await tester.pumpAndSettle();
      expect(find.byType(CreateRepositorySheet), findsNothing);
    },
  );

  testWidgets(
    'GitLab mode with a README wires origin and pushes the initial commit',
    (tester) async {
      final (stub, exec, _) = await _pumpConnected(tester);
      await _next(tester); // Source
      await tester.tap(find.widgetWithText(AppPushButton, 'GitLab'));
      await tester.pumpAndSettle();
      await _next(tester); // Remote → Details
      await tester.enterText(_nameField(), 'new-proj');
      await tester.pumpAndSettle();
      await _tapReadme(tester);
      await _fillIdentity(tester);
      await _next(tester); // Details → Review

      exec.results.add(_ok('absent')); // probe
      exec.results.add(_ok('')); // git init
      _queueIdentityConfig(exec);
      exec.results.add(_ok('')); // git add
      exec.results.add(_ok('')); // git commit
      queueGitlabOriginWire(exec, name: 'new-proj', push: true);
      await tester.tap(_createButton());
      await tester.pumpAndSettle();

      expect(
        exec.calls.map((c) => c.join(' ')),
        containsAllInOrder([
          'git init -b main -- new-proj',
          'git config --local user.name $_testAuthorName',
          'git config --local user.email $_testAuthorEmail',
          _identityCommit,
          'glab repo create new-proj --private --skipGitInit',
          'git remote get-url origin',
          'git remote add origin https://gitlab.com/me/new-proj.git',
          'git -c credential.helper= -c credential.helper=!glab auth git-credential '
              'push -u origin main',
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
      await tester.tap(find.widgetWithText(AppPushButton, 'Custom URL'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<AppPushButton>(_continueButton()).onPressed,
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

  testWidgets('partial forge create (non-zero exit) still wires origin when the '
      'project exists and is discoverable', (tester) async {
    final (stub, exec, _) = await _pumpConnected(tester);
    await _next(tester); // Source
    await tester.tap(find.widgetWithText(AppPushButton, 'GitHub'));
    await tester.pumpAndSettle();
    await _next(tester); // Remote → Details
    await tester.enterText(_nameField(), 'new-proj');
    await tester.pumpAndSettle();
    await _tapReadme(tester);
    await _fillIdentity(tester);
    await _next(tester); // Details → Review

    exec.results.add(_ok('absent')); // probe
    exec.results.add(_ok('')); // git init
    _queueIdentityConfig(exec);
    exec.results.add(_ok('')); // git add
    exec.results.add(_ok('')); // git commit
    // Create exits non-zero after the API project already exists (classic
    // nested-git failure under --source path — or any post-create error).
    exec.results.add(
      const SSHCommandResult(
        exitCode: 1,
        stdout: '',
        stderr: 'failed to add remote: git not found',
      ),
    );
    exec.results.add(noOrigin); // ensure: missing
    exec.results.add(_ok('https')); // git_protocol (probed first)
    exec.results.add(
      _ok(
        '{"url":"https://github.com/me/new-proj","sshUrl":'
        '"git@github.com:me/new-proj.git"}',
      ),
    ); // view still finds the project
    exec.results.add(_ok('')); // remote add
    exec.results.add(_ok('')); // push
    // verify after ensure (downgrade create failure) + step-4 verify
    exec.results.add(_ok('https://github.com/me/new-proj.git\n'));
    exec.results.add(_ok('https://github.com/me/new-proj.git\n'));
    await tester.tap(_createButton());
    await tester.pumpAndSettle();

    expect(
      exec.calls.map((c) => c.join(' ')),
      containsAllInOrder([
        'gh repo create new-proj --private',
        'git remote get-url origin',
        'gh repo view new-proj --json url,sshUrl',
        'git remote add origin https://github.com/me/new-proj.git',
        'git -c credential.helper= -c credential.helper=!gh auth git-credential '
            'push -u origin main',
      ]),
      reason: 'ensure runs after failed create; origin still wired',
    );
    expect(stub.repoPathsSet, ['/srv/new-proj']);
    expect(
      find.byType(CreateRepositorySheet),
      findsNothing,
      reason: 'origin ok → create failure downgraded, sheet pops',
    );
  });

  testWidgets(
    'gh create succeeds but clone URL is unresolvable: the repo is kept '
    'and the sheet warns',
    (tester) async {
      final (stub, exec, _) = await _pumpConnected(tester);
      await _next(tester); // Source
      await tester.tap(find.widgetWithText(AppPushButton, 'GitHub'));
      await tester.pumpAndSettle();
      await _next(tester); // Remote → Details
      await tester.enterText(_nameField(), 'new-proj');
      await tester.pumpAndSettle();
      await _next(tester); // Details → Review

      exec.results.add(_ok('absent')); // probe
      exec.results.add(_ok('')); // git init
      exec.results.add(_ok('')); // gh repo create
      exec.results.add(noOrigin); // ensure: missing
      // All cloneUrl attempts fail (retries included — empty queue → empty ok).
      exec.results.add(
        const SSHCommandResult(exitCode: 1, stdout: '', stderr: 'not found'),
      );
      await _pumpCreate(tester);

      expect(stub.repoPathsSet, [
        '/srv/new-proj',
      ], reason: 'repo is kept and registered');
      expect(
        find.byType(CreateRepositorySheet),
        findsOneWidget,
        reason: 'stays open to show the warning',
      );
      expect(find.textContaining('clone URL could not be'), findsWidgets);
    },
  );

  // --- Existing-folder source -----------------------------------------

  Future<void> toExistingFolder(WidgetTester tester, String path) async {
    await tester.tap(find.widgetWithText(AppPushButton, 'Existing folder'));
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
    stderr:
        'fatal: not a git repository (or any of the parent '
        'directories): .git',
  );
  const unbornHead = SSHCommandResult(exitCode: 1, stdout: '', stderr: '');

  testWidgets('Commit all gates Continue until a git identity is filled', (
    tester,
  ) async {
    await _pumpConnected(tester);
    await toExistingFolder(tester, '/srv/app');
    await _next(tester); // Source
    await _next(tester); // Remote (None)
    expect(
      tester.widget<AppPushButton>(_continueButton()).onPressed,
      isNotNull,
      reason: 'identity is optional until commit-all is on',
    );
    expect(
      tester.widget<MacosTextField>(_authorNameField()).decoration,
      kAppTextFieldDecoration,
    );

    final commitAll = find.byWidgetPredicate(
      (w) =>
          w is MacosTooltip &&
          w.message.startsWith('Commit all existing contents'),
    );
    await tester.ensureVisible(commitAll);
    await tester.pumpAndSettle();
    await tester.tap(commitAll);
    await tester.pumpAndSettle();

    expect(
      tester.widget<AppPushButton>(_continueButton()).onPressed,
      isNull,
      reason: 'commit-all requires name + email',
    );
    expect(
      tester.widget<MacosTextField>(_authorNameField()).decoration,
      kAppTextFieldErrorDecoration,
    );
    expect(
      tester.widget<MacosTextField>(_authorEmailField()).decoration,
      kAppTextFieldErrorDecoration,
    );

    await _fillIdentity(tester);
    expect(
      tester.widget<AppPushButton>(_continueButton()).onPressed,
      isNotNull,
    );
    expect(
      tester.widget<MacosTextField>(_authorNameField()).decoration,
      kAppTextFieldDecoration,
    );
    expect(
      tester.widget<MacosTextField>(_authorEmailField()).decoration,
      kAppTextFieldDecoration,
    );
  });

  testWidgets(
    'existing folder that is not a repo yet: init in place, publish to '
    'GitHub without push',
    (tester) async {
      final (stub, exec, _) = await _pumpConnected(tester);
      await toExistingFolder(tester, '/srv/app');
      await _next(tester); // Source
      await tester.tap(find.widgetWithText(AppPushButton, 'GitHub'));
      await tester.pumpAndSettle();
      await _next(tester); // Remote → Details
      await tester.enterText(_nameField(), 'app-repo');
      await tester.pumpAndSettle();
      await _next(tester); // Details → Review

      exec.results.add(notARepo); // classify: not a repo
      exec.results.add(_ok('')); // git init (in place)
      exec.results.add(unbornHead); // HEAD doesn't resolve — nothing to push
      queueGithubOriginWire(exec, name: 'app-repo');
      await tester.tap(_createButton());
      await tester.pumpAndSettle();

      expect(
        exec.calls.map((c) => c.join(' ')),
        containsAllInOrder([
          'git rev-parse --show-toplevel',
          'git init -b main',
          'git rev-parse --verify --quiet HEAD',
          'gh repo create app-repo --private',
          'git remote add origin https://github.com/me/app-repo.git',
        ]),
      );
      expect(stub.repoPathsSet, [
        '/srv/app',
      ], reason: 'the folder itself becomes the workspace');
      expect(find.byType(CreateRepositorySheet), findsNothing);
    },
  );

  testWidgets('existing repo with history: init skipped, origin wired, commits '
      'pushed with git push -u', (tester) async {
    final (stub, exec, _) = await _pumpConnected(tester);
    await toExistingFolder(tester, '/srv/app');
    await _next(tester); // Source
    await tester.tap(find.widgetWithText(AppPushButton, 'GitHub'));
    await tester.pumpAndSettle();
    await _next(tester); // Remote → Details
    await tester.enterText(_nameField(), 'app-repo');
    await tester.pumpAndSettle();
    await _next(tester); // Details → Review

    exec.results.add(_ok('/srv/app\n')); // classify: repo root
    exec.results.add(noOrigin); // origin guard: nothing wired yet
    exec.results.add(_ok('abc123\n')); // HEAD resolves — history exists
    queueGithubOriginWire(exec, name: 'app-repo', push: true);
    await tester.tap(_createButton());
    await tester.pumpAndSettle();

    expect(
      exec.calls.map((c) => c.join(' ')),
      containsAllInOrder([
        'gh repo create app-repo --private',
        'git remote add origin https://github.com/me/app-repo.git',
        'git -c credential.helper= -c credential.helper=!gh auth git-credential '
            'push -u origin HEAD',
      ]),
    );
    expect(
      exec.calls.map((c) => c.take(2).join(' ')),
      isNot(contains('git init')),
      reason: 'already a repository — never re-inited',
    );
    expect(stub.repoPathsSet, ['/srv/app']);
    expect(find.byType(CreateRepositorySheet), findsNothing);
  });

  testWidgets(
    'existing repo with history does not rewrite identity unless commit-all is on',
    (tester) async {
      final (stub, exec, _) = await _pumpConnected(tester);
      await toExistingFolder(tester, '/srv/app');
      await _next(tester); // Source
      await _next(tester); // Remote (None)
      await _fillIdentity(tester);
      await _next(tester); // Details → Review

      exec.results.add(_ok('/srv/app\n')); // classify: repo root
      exec.results.add(_ok('abc123\n')); // HEAD resolves
      await tester.tap(_createButton());
      await tester.pumpAndSettle();

      final joined = exec.calls.map((c) => c.join(' ')).toList();
      expect(
        joined,
        isNot(contains('git config --local user.name $_testAuthorName')),
        reason: 'alreadyRepo without commit-all must not write user.name',
      );
      expect(
        joined,
        isNot(contains('git config --local user.email $_testAuthorEmail')),
        reason: 'alreadyRepo without commit-all must not write user.email',
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
      await tester.tap(find.widgetWithText(AppPushButton, 'GitHub'));
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
      await tester.tap(find.widgetWithText(AppPushButton, 'Back'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(AppPushButton, 'Back'));
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
      queueGithubOriginWire(exec, name: 'app-repo', push: true);
      await tester.tap(_createButton());
      await tester.pumpAndSettle();

      expect(
        exec.calls.map((c) => c.join(' ')),
        contains('git remote remove origin'),
      );
      expect(
        exec.calls.map((c) => c.join(' ')),
        contains('git remote add origin https://github.com/me/app-repo.git'),
      );
      expect(stub.repoPathsSet, ['/srv/app']);
      expect(find.byType(CreateRepositorySheet), findsNothing);
    },
  );

  testWidgets('a folder nested inside another repo is refused', (tester) async {
    final (stub, exec, _) = await _pumpConnected(tester);
    await toExistingFolder(tester, '/srv/app');
    await _next(tester); // Source
    await tester.tap(find.widgetWithText(AppPushButton, 'GitHub'));
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
      await tester.tap(find.widgetWithText(AppPushButton, 'Custom URL'));
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
      final commitAll = find.byWidgetPredicate(
        (w) =>
            w is MacosTooltip &&
            w.message.startsWith('Commit all existing contents'),
      );
      await tester.ensureVisible(commitAll);
      await tester.pumpAndSettle();
      await tester.tap(commitAll);
      await tester.pumpAndSettle();
      await _fillIdentity(tester);
      await _next(tester); // Details → Review

      exec.results.add(notARepo); // classify: not a repo
      exec.results.add(_ok('')); // git init (in place)
      _queueIdentityConfig(exec);
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
          'git config --local user.name $_testAuthorName',
          'git config --local user.email $_testAuthorEmail',
          'git add --all',
          _identityCommit,
          'git remote add origin $url',
          'git push -u origin HEAD',
          'git remote get-url origin',
        ]),
      );
      expect(stub.repoPathsSet, ['/srv/app']);
      expect(find.byType(CreateRepositorySheet), findsNothing);
    },
  );

  // 0009 H20: Escape (and the title X — both share _requestClose) must not
  // tear the session down under a running create; the footer Cancel is
  // already disabled for exactly that reason.
  testWidgets('Escape during a running create neither closes nor aborts', (
    tester,
  ) async {
    final (stub, exec, _) = await _pumpConnected(tester);
    await _next(tester); // Source
    await _next(tester); // Remote (None)
    await tester.enterText(_nameField(), 'new-proj');
    await tester.pumpAndSettle();
    await _next(tester); // Details → Review

    exec.gate = Completer<void>();
    exec.results.add(_ok('absent')); // probe (parked behind the gate)
    await tester.tap(_createButton());
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    // The mid-flight progress chrome can overflow the tight test surface;
    // drain those non-fatal layout exceptions (same as _pumpCreate).
    // ignore: invalid_use_of_protected_member
    while (tester.takeException() != null) {}
    expect(
      find.byType(CreateRepositorySheet),
      findsOneWidget,
      reason: 'mid-create Escape must be ignored',
    );

    exec.gate!.complete();
    exec.gate = null;
    await tester.pumpAndSettle();
    // ignore: invalid_use_of_protected_member
    while (tester.takeException() != null) {}
    expect(stub.repoPathsSet, ['/srv/new-proj']);
    expect(find.byType(CreateRepositorySheet), findsNothing);
  });
}
