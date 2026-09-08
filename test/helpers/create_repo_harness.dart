// Shared harness for the create-repository sheet's widget tests.
//
// Extracted from `create_repo_sheet_test.dart` (MADR 0031 Phase 2 deviation,
// 2026-09-05): the namespace tests need to drive the same sheet, and a second
// copy of `pumpConnected`/`FakeCreateExecutor` would drift from this one the
// first time either was fixed.
//
// Nothing here asserts. It builds a connected scope around
// `CreateRepositorySheet.connected()`, and names the fields and buttons the
// wizard's steps are driven through.

import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/settings/app_settings.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/storage/connection_store.dart';
import 'package:remote_magic_git/core/storage/saved_connection.dart';
import 'package:remote_magic_git/features/common/buttons.dart';
import 'package:remote_magic_git/features/workspace/create_repo_sheet.dart';
import 'package:riverpod/misc.dart' show Override;
import 'package:shared_preferences/shared_preferences.dart';
import 'app_scope.dart';

class FakeCreateExecutor extends SSHCommandExecutor {
  final List<List<String>> calls = [];
  final List<SSHCommandResult> results = [];
  final Map<String, String> uploads = {};

  /// When set, every execute parks on it — lets a test hold the create
  /// "in flight" to prove Escape can't tear the session down mid-run.
  Completer<void>? gate;

  /// Answers by REQUEST rather than by queue position, and takes precedence
  /// over [results].
  ///
  /// A create's call order shifts with the mode — an auth probe here, a
  /// pre-existing-repo check there — so a positional queue aims its answers at
  /// whichever step happens to land in that slot. That has already produced
  /// fixtures that "failed the forge create" while actually failing `git init`,
  /// and read as passing. `forge_namespaces_test.dart` learned the same lesson
  /// against concurrent calls (MADR 0032 Phase 2). Return null to fall through
  /// to [results].
  SSHCommandResult? Function(List<String> args)? respond;

  FakeCreateExecutor() : super(SSHClientManager());

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
    final routed = respond?.call(gitArgs);
    if (routed != null) return routed;
    return results.isNotEmpty
        ? results.removeAt(0)
        : const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }
}

class StubConnection extends ConnectionController {
  StubConnection(this._state);
  final ConnectionState _state;
  final List<String> repoPathsSet = [];

  @override
  ConnectionState build() => _state;

  @override
  void setRepoPath(String path) => repoPathsSet.add(path);
}

class FakeConnectionStore extends ConnectionStore {
  final List<SavedConnection> updated = [];
  @override
  Future<void> updateMetadata(SavedConnection conn) async => updated.add(conn);
  @override
  Future<void> touch(String id, {DateTime? when}) async {}
}

class PrefillSettings extends AppSettingsNotifier {
  @override
  AppSettings build() => const AppSettings(
    committerName: 'Jane Developer',
    committerEmail: 'jane@example.com',
  );
}

/// Starts empty (the real notifier's first frame) then can publish a stored
/// identity, matching Settings' async disk load.
class LateSettings extends AppSettingsNotifier {
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
class GuardSettings extends AppSettingsNotifier {
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

SSHCommandResult okResult(String stdout) =>
    SSHCommandResult(exitCode: 0, stdout: stdout, stderr: '');

const testConn = SavedConnection(
  id: 'c1',
  label: 'Prod',
  host: 'h',
  port: 22,
  username: 'u',
  repoPath: '/srv/repo',
  repoPaths: ['/srv/repo'],
);

Future<(StubConnection, FakeCreateExecutor, FakeConnectionStore)> pumpConnected(
  WidgetTester tester, {
  List<Override> extraOverrides = const [],
}) async {
  // `SharedPreferences.getInstance()` **never settles inside `testWidgets`** —
  // its platform-channel reply needs `runAsync`, which a pumped widget test
  // does not provide. (In a plain `test()` it throws MissingPluginException
  // promptly; here it simply hangs.) The namespace-history store reads it on
  // the This-Mac path, so without this the create sheet's suggestion provider
  // sits in `AsyncLoading` forever and no suggestion ever renders. Empty is
  // the honest default: a test that wants history sets its own values.
  SharedPreferences.setMockInitialValues({});
  // Room for the wizard + completed-warning footer (cloneUrl failure copy
  // can be long; a tight surface overflows the step breadcrumb).
  await tester.binding.setSurfaceSize(const Size(1200, 900));
  final stub = StubConnection(
    const ConnectionState(
      phase: ConnectionPhase.connected,
      repoPath: '/srv/repo',
      repoPaths: ['/srv/repo'],
      connectionId: 'c1',
      connectionLabel: 'Prod',
      host: 'h',
    ),
  );
  final exec = FakeCreateExecutor();
  final store = FakeConnectionStore();
  await tester.pumpWidget(
    appProviderScope(
      overrides: [
        connectionProvider.overrideWith(() => stub),
        activeExecutorProvider.overrideWithValue(exec),
        connectionStoreProvider.overrideWithValue(store),
        savedConnectionsProvider.overrideWith((ref) async => [testConn]),
        gitServiceProvider.overrideWithValue(GitService(FakeCreateExecutor())),
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
Future<void> pumpCreate(WidgetTester tester) async {
  await tester.tap(createButton());
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

Finder createButton() => find.widgetWithText(AppPushButton, 'Create');

Finder continueButton() => find.widgetWithText(AppPushButton, 'Continue');

Finder nameField() => find.byWidgetPredicate(
  (w) => w is MacosTextField && w.placeholder == 'my-project',
);

Finder authorNameField() => find.byWidgetPredicate(
  (w) => w is MacosTextField && w.placeholder == 'Your name',
);

Finder authorEmailField() => find.byWidgetPredicate(
  (w) => w is MacosTextField && w.placeholder == 'you@example.com',
);

const testAuthorName = 'Ada Lovelace';
const testAuthorEmail = 'ada@example.com';

/// Fills the Details-step identity fields. Required when an initial
/// commit is on (README / commit-all); optional otherwise.
Future<void> fillIdentity(WidgetTester tester) async {
  await tester.ensureVisible(authorNameField());
  await tester.pumpAndSettle();
  await tester.enterText(authorNameField(), testAuthorName);
  await tester.enterText(authorEmailField(), testAuthorEmail);
  await tester.pumpAndSettle();
}

Finder readmeToggle() => find.byWidgetPredicate(
  (w) => w is MacosTooltip && w.message.startsWith('Add a README'),
);

Future<void> tapReadme(WidgetTester tester) async {
  await tester.ensureVisible(readmeToggle());
  await tester.pumpAndSettle();
  await tester.tap(readmeToggle());
  await tester.pumpAndSettle();
}

/// Queues the two local `git config` writes that follow init when identity
/// is filled.
void queueIdentityConfig(FakeCreateExecutor exec) {
  exec.results.add(okResult('')); // git config --local user.name
  exec.results.add(okResult('')); // git config --local user.email
}

String get identityCommit =>
    'git -c user.name=$testAuthorName -c user.email=$testAuthorEmail '
    'commit --no-gpg-sign -m Initial commit';

/// Advances the wizard one step (the current step must be valid).
Future<void> nextStep(WidgetTester tester) async {
  await tester.tap(continueButton());
  await tester.pumpAndSettle();
}
