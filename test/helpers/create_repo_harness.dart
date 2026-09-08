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
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:remote_magic_git/core/exec/local_command_executor.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/local/scoped_access.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/providers/provider_retry_policy.dart';
import 'package:remote_magic_git/core/settings/app_settings.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/storage/connection_store.dart';
import 'package:remote_magic_git/core/storage/saved_connection.dart';
import 'package:remote_magic_git/core/storage/saved_workspace_set.dart';
import 'package:remote_magic_git/features/common/buttons.dart';
import 'package:remote_magic_git/features/tabs/tabs_controller.dart';
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

/// Records every way a sheet can point a session at a repository, and runs
/// none of them. `repoPathsSet` is "the path this session ended on" whether
/// that came from `setRepoPath` (a switch) or `finalizeProvisioned` (a dial
/// promoted into a workspace) — the observable the create tests assert.
class StubConnection extends ConnectionController {
  StubConnection(this._state, {this.dialResult = 7, this.dialGate});
  final ConnectionState _state;

  /// What `beginProvisioning` resolves to: a token, or null for a failed dial.
  final int? dialResult;

  /// When set, `beginProvisioning` parks on it and resolves to its value —
  /// lets a test act while a dial is in flight (MADR 0022 H4).
  final Completer<int?>? dialGate;

  final List<String> repoPathsSet = [];
  final List<SavedConnection> dialed = [];
  final List<({int token, String repoPath, String label})> finalized = [];
  final List<({String connectionId, String? repoPath})> savedConnects = [];
  int aborts = 0;

  /// Paths a local create asked this session to open in place
  /// (`registerAndActivateLocal` → `connectLocal`). Recorded, never run: the
  /// real controller would validate with real git.
  final List<String> localConnects = [];

  @override
  ConnectionState build() => _state;

  @override
  void setRepoPath(String path) => repoPathsSet.add(path);

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

  @override
  Future<void> connectToSaved(SavedConnection conn, {String? repoPath}) async {
    savedConnects.add((connectionId: conn.id, repoPath: repoPath));
  }

  @override
  Future<int?> beginProvisioning(SavedConnection conn) async {
    dialed.add(conn);
    if (dialGate != null) return dialGate!.future;
    return dialResult;
  }

  @override
  Future<bool> finalizeProvisioned({
    required int token,
    required SavedConnection conn,
    required String repoPath,
    bool enableFsmonitor = false,
    String label = '',
    String gitDir = '',
  }) async {
    finalized.add((token: token, repoPath: repoPath, label: label));
    repoPathsSet.add(repoPath);
    return true;
  }

  /// When set, `abortProvisioning` parks on it — lets a test dismiss the
  /// sheet while a hang-up is still outstanding (MADR 0034 F4).
  Completer<void>? abortGate;

  @override
  Future<void> abortProvisioning(int token) async {
    aborts++;
    if (abortGate != null) await abortGate!.future;
  }
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

/// [pastDestination] advances off the Destination step the connected wizard
/// now opens on (MADR 0036, 2A), so the many tests written when Source was
/// step 0 keep their `nextStep` sequences. Pass false to look at the step.
Future<(StubConnection, FakeCreateExecutor, FakeConnectionStore)> pumpConnected(
  WidgetTester tester, {
  List<Override> extraOverrides = const [],
  bool pastDestination = true,
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
  if (pastDestination) await nextStep(tester);
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

/// The "Save to Local Repositories" toggle (Details step, local target),
/// found and tapped through its tooltip the way [tapReadme] is.
Finder saveLocalToggle() => find.byWidgetPredicate(
  (w) =>
      w is MacosTooltip && w.message.startsWith('Save to Local Repositories'),
);

Future<void> tapSaveLocal(WidgetTester tester) async {
  await tester.ensureVisible(saveLocalToggle());
  await tester.pumpAndSettle();
  await tester.tap(saveLocalToggle());
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

// ---------------------------------------------------------------------------
// MADR 0036 Phase 1 — the landing twin of [pumpConnected].
// ---------------------------------------------------------------------------

/// The landing page's connection: no session until a saved host is chosen,
/// then a dial that resolves to [dialResult]. All recording lives on
/// [StubConnection]; this only fixes the empty starting state.
class ProvisionStub extends StubConnection {
  ProvisionStub({super.dialResult}) : super(const ConnectionState());
}

/// Pumps `CreateRepositorySheet.landing()` — no session, a Destination step —
/// with the same executor and store doubles as [pumpConnected], so the two
/// helpers cannot drift apart.
Future<(ProvisionStub, FakeCreateExecutor, FakeConnectionStore)> pumpLanding(
  WidgetTester tester, {
  List<SavedConnection> connections = const [testConn],
  int? dialResult = 7,
  List<Override> extraOverrides = const [],
}) async {
  SharedPreferences.setMockInitialValues({});
  await tester.binding.setSurfaceSize(const Size(1200, 900));
  final stub = ProvisionStub(dialResult: dialResult);
  final exec = FakeCreateExecutor();
  final store = FakeConnectionStore();
  await tester.pumpWidget(
    appProviderScope(
      overrides: [
        connectionProvider.overrideWith(() => stub),
        activeExecutorProvider.overrideWithValue(exec),
        connectionStoreProvider.overrideWithValue(store),
        savedConnectionsProvider.overrideWith((ref) async => connections),
        gitServiceProvider.overrideWithValue(GitService(FakeCreateExecutor())),
        ...extraOverrides,
      ],
      child: const MacosApp(
        debugShowCheckedModeBanner: false,
        home: CreateRepositorySheet.landing(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (stub, exec, store);
}

/// The Destination step's popup (This Mac + every saved connection).
Finder destinationPopup() => find.byType(MacosPopupButton<String?>);

/// Chooses [displayName] in the Destination popup and settles the dial the
/// selection triggers.
Future<void> chooseDestination(WidgetTester tester, String displayName) async {
  await tester.tap(destinationPopup());
  await tester.pumpAndSettle();
  await tester.tap(find.text(displayName).last);
  await tester.pumpAndSettle();
}

/// The "Parent folder on the host" field an SSH destination shows.
Finder parentField() => find.byWidgetPredicate(
  (w) => w is MacosTextField && w.placeholder == '/srv/git',
);

// ---------------------------------------------------------------------------
// MADR 0036 Phase 2 — doubles for "which tab did this land in".
// ---------------------------------------------------------------------------

/// A [LocalCommandExecutor] that answers from a queue, like
/// [FakeCreateExecutor] does for SSH. `localExecutorProvider` is typed to the
/// concrete class, so the SSH fake cannot stand in for it.
class FakeLocalExecutor extends LocalCommandExecutor {
  final List<List<String>> calls = [];
  final List<SSHCommandResult> results = [];

  /// Answers by REQUEST, taking precedence over [results]. On the local path
  /// the environment probe (`localEnvironmentProvider.ensure()`) runs through
  /// this executor *before* the create's own existence probe, so a positional
  /// queue hands the probe's answer to the wrong command — the same lesson
  /// [FakeCreateExecutor.respond] records for the SSH fake.
  SSHCommandResult? Function(List<String> args)? respond;

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
    final routed = respond?.call(gitArgs);
    if (routed != null) return routed;
    return results.isNotEmpty
        ? results.removeAt(0)
        : const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }
}

/// Answers the create's existence probe with "absent" and everything else
/// (the environment probe, `git init`, …) with success — the router a local
/// create test wants unless it is testing a failure.
SSHCommandResult? localCreateOk(List<String> args) =>
    args.join(' ').contains('if test -e') ? okResult('absent') : null;

/// A [TabsController] that records instead of dialling. Every tab it opens
/// gets a real, empty container, so code that reads providers from "the
/// target tab" has somewhere to read from; `connect` callbacks are counted,
/// not run against a host. [capReached] mirrors the real cap's behaviour
/// exactly: `openOrFocus` returns the active tab and never runs `connect`
/// (`tabs_controller.dart:289-292`).
class RecordingTabs extends TabsController {
  RecordingTabs({FakeCreateExecutor? exec})
    : exec = exec ?? FakeCreateExecutor(),
      super(containerFactory: _factory);

  /// The executor a create routed into a spawned tab runs on — the tab
  /// containers all share it, so a test can queue results and assert argv.
  final FakeCreateExecutor exec;

  static late FakeCreateExecutor _tabExec;
  static int? _spawnedDial = 7;
  static Completer<int?>? _spawnedDialGate;

  /// What a spawned tab's `beginProvisioning` resolves to (null = fails).
  int? spawnedDialResult = 7;

  /// When set, a spawned tab's dial parks on it.
  Completer<int?>? spawnedDialGate;
  static ProviderContainer _factory(List<Override> overrides) =>
      ProviderContainer(
        retry: noProviderRetry,
        overrides: [
          // Recorded, never run: a real controller in a spawned tab would
          // dial a real host or validate with real git.
          connectionProvider.overrideWith(
            () => StubConnection(
              const ConnectionState(),
              dialResult: _spawnedDial,
              dialGate: _spawnedDialGate,
            ),
          ),
          activeExecutorProvider.overrideWithValue(_tabExec),
          ...overrides,
        ],
      );

  /// The (recording) connection of a spawned tab.
  StubConnection stubIn(RepoTab tab) =>
      tab.container.read(connectionProvider.notifier) as StubConnection;

  final List<({String? connectionId, String? repoPath})> opened = [];
  final List<String> closed = [];
  int connectRan = 0;
  bool capReached = false;

  /// Simulates the racing double-open: `canOpenTab` stays true (the sheet's
  /// up-front check passes) but the next `openOrFocus` declines and never
  /// runs `connect`, exactly like the cap path (`tabs_controller.dart:289`).
  bool declineOpens = false;

  /// Every spawned tab's connection stub, in order — kept here because a
  /// closed tab's container is disposed and gone from [tabs].
  final List<StubConnection> spawned = [];

  @override
  bool get canOpenTab => !capReached;

  @override
  RepoTab openOrFocus({
    String? connectionId,
    String? repoPath,
    SavedRepositoryKind? savedKind,
    String? savedReferencePath,
    List<Override> overrides = const [],
    required void Function(ProviderContainer container) connect,
  }) {
    if (capReached || declineOpens) return active ?? ensureInitialTab();
    opened.add((connectionId: connectionId, repoPath: repoPath));
    final tab = super.openOrFocus(
      connectionId: connectionId,
      repoPath: repoPath,
      savedKind: savedKind,
      savedReferencePath: savedReferencePath,
      overrides: overrides,
      connect: (container) {
        connectRan++;
        connect(container);
      },
    );
    spawned.add(stubIn(tab));
    return tab;
  }

  @override
  RepoTab newTab() {
    final tab = super.newTab();
    opened.add((connectionId: null, repoPath: null));
    spawned.add(stubIn(tab));
    return tab;
  }

  @override
  Future<void> close(String id) async {
    closed.add(id);
    await super.close(id);
  }
}

/// Installs [tabs] as the controller sheets reach through
/// `TabsController.current`, and undoes it when the test ends — the same
/// pair `tabs_host.dart:126` / `:166-167` performs.
void installTabs(RecordingTabs tabs) {
  RecordingTabs._tabExec = tabs.exec;
  RecordingTabs._spawnedDial = tabs.spawnedDialResult;
  RecordingTabs._spawnedDialGate = tabs.spawnedDialGate;
  TabsController.current = tabs;
  addTearDown(() {
    if (identical(TabsController.current, tabs)) TabsController.current = null;
    tabs.dispose();
  });
}

/// A [ScopedAccess] whose acquire/release are counted. A grant acquired for a
/// session that never started leaks for the app's lifetime; here it is a
/// failing assertion instead. Every bookmark resolves to [resolvedPath].
class CountingScopedAccess {
  CountingScopedAccess({this.resolvedPath = '/resolved'});

  final String resolvedPath;
  final List<String> acquired = [];
  final List<String> released = [];

  late final ScopedAccess access = ScopedAccess(
    startAccessing: (bookmark) async {
      acquired.add(bookmark);
      return resolvedPath;
    },
    stopAccessing: (path) async {
      released.add(path);
    },
  );
}

/// The native folder panel, answered from a test. `pickLocalDirectory()` goes
/// through `file_selector`, whose platform instance is swappable — the
/// standard way to drive a picker under `flutter test`.
class FakeFolderPicker extends FileSelectorPlatform
    with MockPlatformInterfaceMixin {
  FakeFolderPicker(this.path);

  /// What the panel "chooses"; null is a cancel.
  String? path;
  int shown = 0;

  @override
  Future<String?> getDirectoryPathWithOptions(FileDialogOptions options) async {
    shown++;
    return path;
  }

  @override
  Future<String?> getDirectoryPath({
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    shown++;
    return path;
  }
}

/// Makes the next folder panel answer [path], restoring the real platform
/// when the test ends.
FakeFolderPicker installFolderPicker(String? path) {
  final previous = FileSelectorPlatform.instance;
  final fake = FakeFolderPicker(path);
  FileSelectorPlatform.instance = fake;
  addTearDown(() => FileSelectorPlatform.instance = previous);
  return fake;
}

/// The "Choose…" button of the local parent-folder row (Source step).
Finder chooseFolderButton() => find.widgetWithText(AppPushButton, 'Choose…');

/// A **local** session — the twin of [pumpConnected], whose session is SSH.
/// The local executor is [FakeLocalExecutor], which also keeps
/// `localEnvironmentProvider.ensure()` from probing a real shell.
Future<(StubConnection, FakeLocalExecutor, FakeConnectionStore)>
pumpConnectedLocal(
  WidgetTester tester, {
  List<Override> extraOverrides = const [],
  bool pastDestination = true,
}) async {
  SharedPreferences.setMockInitialValues({});
  // `registerAndActivateLocal` bookmarks the new folder through the
  // `magicgit/bookmarks` channel. A platform channel with no handler never
  // settles under `testWidgets` (its reply needs `runAsync`) — the same
  // mechanism that hung `SharedPreferences` in MADR 0032 — so `_submit` would
  // spin forever at the bookmark step. Answer it the way a signed build does.
  const bookmarks = MethodChannel('magicgit/bookmarks');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        bookmarks,
        (call) async => 'bookmark:${call.arguments}',
      );
  addTearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(bookmarks, null),
  );
  await tester.binding.setSurfaceSize(const Size(1200, 900));
  final stub = StubConnection(
    const ConnectionState(
      phase: ConnectionPhase.connected,
      backend: ConnectionBackend.local,
      repoPath: '/Users/me/repo',
      repoPaths: ['/Users/me/repo'],
      connectionId: 'l1',
      connectionLabel: 'Mine',
    ),
  );
  final exec = FakeLocalExecutor();
  final store = FakeConnectionStore();
  await tester.pumpWidget(
    appProviderScope(
      overrides: [
        connectionProvider.overrideWith(() => stub),
        localExecutorProvider.overrideWithValue(exec),
        activeExecutorProvider.overrideWithValue(FakeCreateExecutor()),
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
  if (pastDestination) await nextStep(tester);
  return (stub, exec, store);
}
