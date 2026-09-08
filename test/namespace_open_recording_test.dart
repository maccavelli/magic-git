// MADR 0037 Phase 2 — opening a repository teaches the create sheet where you
// work.
//
// The gap this closes: local history records only what this app *wrote*
// (creates and clones), and the forge events feed sees 7 days and one
// 100-event page. A repository you joined and only ever *open* is invisible to
// both, however often you work in it.
//
// Decision 1 (2026-09-08): only namespaces the account can **create** in are
// recorded, so the store is clean rather than filtered at read time. An
// unknown answer records nothing.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/exec/local_command_executor.dart';
import 'package:remote_magic_git/core/forge/forge.dart';
import 'package:remote_magic_git/core/forge/namespace_history.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/providers/provider_retry_policy.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/storage/connection_store.dart';
import 'package:remote_magic_git/core/storage/recent_repos_store.dart';
import 'package:remote_magic_git/core/storage/saved_connection.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Answers the creatable-namespace lookup, and counts how often it was asked —
/// the memo's contract is one lookup per (forge, host) per session.
class _ForgeExecutor extends SSHCommandExecutor {
  _ForgeExecutor({this.groups = const ['team/subgroup', 'platform']})
    : super(SSHClientManager());

  final List<String> groups;
  int userCalls = 0;
  bool fail = false;

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
    final joined = gitArgs.join(' ');
    if (fail) {
      return const SSHCommandResult(exitCode: 1, stdout: '', stderr: 'down');
    }
    if (joined.contains('api') && joined.contains('user')) {
      userCalls++;
      return _headers('{"username":"me"}');
    }
    if (joined.contains('groups')) {
      return _headers('[${groups.map((g) => '{"full_path":"$g"}').join(',')}]');
    }
    return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  static SSHCommandResult _headers(String body) => SSHCommandResult(
    exitCode: 0,
    stdout: 'HTTP/2.0 200 OK\r\n\r\n$body',
    stderr: '',
  );
}

/// A [GitService] whose `originUrl` answers from a map — the session cache the
/// real one reads is already covered by Phase 1's own tests.
class _OriginGit extends GitService {
  _OriginGit(this._urls) : super(_ForgeExecutor());
  final Map<String, String?> _urls;
  int calls = 0;

  @override
  Future<String?> originUrl(String repoPath, {String remote = 'origin'}) async {
    calls++;
    return _urls[repoPath];
  }

  // The real `connectLocal` validates before it records; a local open in these
  // tests is about the recording, not about git.
  @override
  Future<void> validateRepoPath(String repoPath) async {}

  @override
  Future<RepoLayout?> validateLocalRepoRoot(String repoPath) async => null;
}

/// Records the per-repo MRU writes without touching SharedPreferences.
class _RecordingRecents extends RecentReposStore {
  final List<String> records = [];

  @override
  Future<void> record({
    required bool isLocal,
    required String id,
    required String repoPath,
    DateTime? when,
  }) async => records.add(repoPath);

  @override
  Future<List<RecentRepoRef>> list() async => const [];
}

/// The This-Mac executor a local session's creatable lookup goes through:
/// `ConnectionController._activeExecutor` switches on the backend, so a local
/// open reads `localExecutorProvider`, not `executorProvider`.
class _LocalForgeExecutor extends LocalCommandExecutor {
  _LocalForgeExecutor() {
    // Non-empty so the environment guard treats it as already probed.
    configureEnvironment(path: '/usr/bin', binaries: const {});
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
    final joined = gitArgs.join(' ');
    if (joined.contains('api') && joined.contains('user')) {
      return _ForgeExecutor._headers('{"username":"me"}');
    }
    if (joined.contains('groups')) {
      return _ForgeExecutor._headers('[{"full_path":"team/subgroup"}]');
    }
    return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }
}

class _FakeStore extends ConnectionStore {
  final List<SavedConnection> updated = [];
  bool throwOnWrite = false;

  @override
  Future<void> updateMetadata(SavedConnection conn) async {
    if (throwOnWrite) throw StateError('store unwritable');
    updated.add(conn);
  }

  @override
  Future<void> touch(String id, {DateTime? when}) async {}
}

class _TestConnection extends ConnectionController {
  void force(ConnectionState next) => state = next;
}

const _conn = SavedConnection(
  id: 'c1',
  label: 'Prod',
  host: 'h',
  port: 22,
  username: 'u',
  repoPath: '/srv/repo',
  repoPaths: ['/srv/repo'],
);

void main() {
  late _FakeStore store;
  late _ForgeExecutor forge;

  ProviderContainer build({
    required Map<String, String?> origins,
    List<String> groups = const ['team/subgroup', 'platform'],
    bool forgeDown = false,
    _OriginGit? git,
  }) {
    SharedPreferences.setMockInitialValues({});
    store = _FakeStore();
    forge = _ForgeExecutor(groups: groups)..fail = forgeDown;
    return ProviderContainer(
      retry: noProviderRetry,
      overrides: [
        connectionProvider.overrideWith(_TestConnection.new),
        executorProvider.overrideWithValue(forge),
        gitServiceProvider.overrideWithValue(git ?? _OriginGit(origins)),
        connectionStoreProvider.overrideWithValue(store),
        savedConnectionsProvider.overrideWith((ref) async => [_conn]),
      ],
    );
  }

  /// Opens [repoPath] on a connected SSH session — `setRepoPath` is the public
  /// door onto the recording path.
  Future<void> open(ProviderContainer c, String repoPath) async {
    final controller = c.read(connectionProvider.notifier) as _TestConnection;
    controller.force(
      const ConnectionState(
        phase: ConnectionPhase.connected,
        repoPath: '/srv/repo',
        repoPaths: ['/srv/repo'],
        connectionId: 'c1',
        connectionLabel: 'Prod',
        host: 'h',
      ),
    );
    controller.setRepoPath(repoPath);
    // `setRepoPath` fires the recording unawaited, as an open must never wait
    // on its own bookkeeping.
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  List<String> recorded() => store.updated.isEmpty
      ? const []
      : store.updated.last.namespacesFor(
          namespaceHistoryKey(Forge.gitlab, 'gitlab.example'),
        );

  test('an SSH open records its namespace onto the connection', () async {
    final c = build(
      origins: {'/srv/app': 'https://gitlab.example/team/subgroup/app.git'},
    );
    addTearDown(c.dispose);
    await open(c, '/srv/app');
    expect(recorded(), ['team/subgroup']);
  });

  test('a namespace the account cannot create in records nothing', () async {
    // Decision 1: the store is clean, not filtered at read time.
    final c = build(
      origins: {'/srv/app': 'https://gitlab.example/someone-else/app.git'},
    );
    addTearDown(c.dispose);
    await open(c, '/srv/app');
    expect(store.updated, isEmpty);
  });

  test('a failed creatable lookup records nothing', () async {
    // Unknown is not creatable. The next open on a reachable forge records it.
    final c = build(
      origins: {'/srv/app': 'https://gitlab.example/team/subgroup/app.git'},
      forgeDown: true,
    );
    addTearDown(c.dispose);
    await open(c, '/srv/app');
    expect(store.updated, isEmpty);
  });

  test('two opens on one host issue a single creatable lookup', () async {
    final c = build(
      origins: {
        '/srv/app': 'https://gitlab.example/team/subgroup/app.git',
        '/srv/api': 'https://gitlab.example/platform/api.git',
      },
    );
    addTearDown(c.dispose);
    await open(c, '/srv/app');
    await open(c, '/srv/api');
    expect(
      forge.userCalls,
      1,
      reason: 'memoised per (forge, host) — without it, one per open',
    );
  });

  test('a repo with no origin records nothing', () async {
    final c = build(origins: {'/srv/app': null});
    addTearDown(c.dispose);
    await open(c, '/srv/app');
    expect(store.updated, isEmpty);
  });

  test('a non-forge origin records nothing', () async {
    final c = build(origins: {'/srv/app': 'https://example.com/team/app.git'});
    addTearDown(c.dispose);
    await open(c, '/srv/app');
    expect(store.updated, isEmpty);
  });

  test('a path with no namespace above it records nothing', () async {
    // `host/app` has no namespace above the project. Without the last-slash
    // guard the whole path becomes the "namespace" — so `app` is deliberately
    // in the creatable list here, or the creatable check would mask the guard
    // and this test would pass either way.
    final c = build(
      origins: {'/srv/app': 'https://gitlab.example/app.git'},
      groups: const ['app', 'team/subgroup'],
    );
    addTearDown(c.dispose);
    await open(c, '/srv/app');
    expect(store.updated, isEmpty);
  });

  // MADR 0038 F9.2 — an UNSAVED local open has no id, so nothing goes into the
  // per-repo MRU. The namespace is a different matter: it was being dropped
  // only because it shared a guard with the MRU write.
  test(
    'an unsaved local open records its namespace but no MRU entry',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = _FakeStore();
      final recents = _RecordingRecents();
      final c = ProviderContainer(
        retry: noProviderRetry,
        overrides: [
          gitServiceProvider.overrideWithValue(
            _OriginGit({
              '/Users/me/app': 'https://gitlab.example/team/subgroup/app.git',
            }),
          ),
          localExecutorProvider.overrideWithValue(_LocalForgeExecutor()),
          connectionStoreProvider.overrideWithValue(store),
          recentReposStoreProvider.overrideWithValue(recents),
          savedConnectionsProvider.overrideWith((ref) async => const []),
        ],
      );
      addTearDown(c.dispose);

      // `id: null` is what an unsaved local create/clone/open passes.
      await c
          .read(connectionProvider.notifier)
          .connectLocal('/Users/me/app', label: 'App');
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(recents.records, isEmpty, reason: 'nothing to reopen from');
      expect(
        await NamespaceHistory(
          store,
        ).recent(forge: Forge.gitlab, host: 'gitlab.example'),
        ['team/subgroup'],
        reason: 'a This-Mac history goes to the prefs store, not a connection',
      );
    },
  );

  test('a throwing store does not fail the open', () async {
    final c = build(
      origins: {'/srv/app': 'https://gitlab.example/team/subgroup/app.git'},
    );
    addTearDown(c.dispose);
    store.throwOnWrite = true;
    await open(c, '/srv/app');
    expect(
      c.read(connectionProvider).repoPath,
      '/srv/app',
      reason: 'the open stands; only the bookkeeping failed',
    );
  });
}
