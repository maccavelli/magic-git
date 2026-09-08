// MADR 0037 Phase 3 — the retroactive half: learn namespaces from the
// repositories already in the recents list.
//
// The rule the whole file exists to pin: **nothing here dials.** A saved SSH
// host with no live session is skipped, never connected to, because this runs
// while the create sheet is opening and must not make the wizard wait on a
// handshake. What is reachable without one — a bookmarked local repo, and an
// SSH repo whose host a tab already holds a session on — is read; everything
// else waits for the next open (Phase 2).

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/exec/local_command_executor.dart';
import 'package:remote_magic_git/core/forge/forge.dart';
import 'package:remote_magic_git/core/forge/namespace_backfill.dart';
import 'package:remote_magic_git/core/forge/namespace_history.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/local/scoped_access.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/providers/provider_retry_policy.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/storage/connection_store.dart';
import 'package:remote_magic_git/core/storage/recent_repos_store.dart';
import 'package:remote_magic_git/core/storage/saved_connection.dart';
import 'package:remote_magic_git/core/storage/saved_local_repo.dart';
import 'package:remote_magic_git/features/tabs/tabs_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/create_repo_harness.dart' show CountingScopedAccess;

/// Answers the creatable-namespace lookup. Shared with the Phase 2 harness in
/// shape: `groups` is what the account may create in.
class _ForgeExecutor extends SSHCommandExecutor {
  _ForgeExecutor({this.groups = const ['team/subgroup', 'platform']})
    : super(SSHClientManager());

  final List<String> groups;

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

/// The This-Mac executor the local half of the scan runs `git remote get-url`
/// through. Records every call, with its `extraEnv`, so "was this read at all,
/// and under which scope?" is assertable. A path absent from [urls] answers
/// like a repo with no origin: exit 1.
class _LocalExec extends LocalCommandExecutor {
  _LocalExec(this.urls) {
    // Non-empty config so `LocalEnvironmentGuard.ensure()` is a no-op rather
    // than probing the real machine.
    configureEnvironment(
      path: '/usr/bin',
      binaries: const {'git': '/usr/bin/git'},
    );
  }

  final Map<String, String> urls;
  final List<String> readPaths = [];
  final List<Map<String, String>?> envs = [];

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
    readPaths.add(repoPath);
    envs.add(extraEnv);
    final url = urls[repoPath];
    if (url == null) {
      return const SSHCommandResult(
        exitCode: 1,
        stdout: '',
        stderr: 'no remote',
      );
    }
    return SSHCommandResult(exitCode: 0, stdout: '$url\n', stderr: '');
  }
}

/// A failure that is deliberately **not** a [StateError]: the scan treats
/// `StateError` as "the container is gone, stop", so using one here would
/// prove the opposite of what the "one bad repo does not stop the rest" test
/// claims.
class ProcessFailure implements Exception {
  const ProcessFailure();
}

/// A [GitService] whose `originUrl` answers from a map, for the tab that holds
/// the live SSH session.
class _OriginGit extends GitService {
  _OriginGit(this._urls) : super(_ForgeExecutor());
  final Map<String, String?> _urls;
  final List<String> asked = [];

  @override
  Future<String?> originUrl(String repoPath, {String remote = 'origin'}) async {
    asked.add(repoPath);
    return _urls[repoPath];
  }
}

class _FakeStore extends ConnectionStore {
  final List<SavedConnection> updated = [];

  @override
  Future<void> updateMetadata(SavedConnection conn) async => updated.add(conn);

  @override
  Future<void> touch(String id, {DateTime? when}) async {}
}

class _TestConnection extends ConnectionController {
  void force(ConnectionState next) => state = next;
}

/// A guard that never probes the real machine.
class _NoopGuard extends LocalEnvironmentGuard {
  _NoopGuard(super.ref);
  @override
  Future<void> ensure() async {}
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

RecentRepoRef _local(String id, String path, {DateTime? at}) => RecentRepoRef(
  isLocal: true,
  id: id,
  repoPath: path,
  openedAt: at ?? DateTime.utc(2026, 8, 1),
);

RecentRepoRef _ssh(String path, {String id = 'c1', DateTime? at}) =>
    RecentRepoRef(
      isLocal: false,
      id: id,
      repoPath: path,
      openedAt: at ?? DateTime.utc(2026, 8, 2),
    );

SavedLocalRepo _saved(
  String id,
  String path, {
  String bookmark = 'bm',
  String gitDir = '',
  String mainBookmark = '',
}) => SavedLocalRepo(
  id: id,
  label: id,
  repoPath: path,
  bookmarkData: bookmark,
  gitDir: gitDir,
  mainRepoBookmarkData: mainBookmark,
);

void main() {
  late _FakeStore store;
  late _LocalExec localExec;
  late CountingScopedAccess grants;

  setUp(() => TabsController.current = null);
  tearDown(() => TabsController.current = null);

  ProviderContainer build({
    List<RecentRepoRef> recents = const [],
    List<SavedLocalRepo> saved = const [],
    Map<String, String> localUrls = const {},
    List<String> groups = const ['team/subgroup', 'platform'],
    String resolvedPath = '/resolved',
  }) {
    SharedPreferences.setMockInitialValues({});
    store = _FakeStore();
    localExec = _LocalExec(localUrls);
    grants = CountingScopedAccess(resolvedPath: resolvedPath);
    return ProviderContainer(
      retry: noProviderRetry,
      overrides: [
        connectionProvider.overrideWith(_TestConnection.new),
        executorProvider.overrideWithValue(_ForgeExecutor(groups: groups)),
        localExecutorProvider.overrideWithValue(localExec),
        localEnvironmentProvider.overrideWith(_NoopGuard.new),
        connectionStoreProvider.overrideWithValue(store),
        savedConnectionsProvider.overrideWith((ref) async => [_conn]),
        savedLocalReposProvider.overrideWith((ref) async => saved),
        recentRepoRefsProvider.overrideWith((ref) async => recents),
      ],
    );
  }

  /// A tabs controller holding one tab whose session state is [state] and
  /// whose `GitService` is [git]. `TabsController.current` is the seam the
  /// scan reads, exactly as the app sets it.
  TabsController tabsWith(ConnectionState state, _OriginGit git) {
    final controller = TabsController(
      containerFactory: (overrides) => ProviderContainer(
        retry: noProviderRetry,
        overrides: [
          connectionProvider.overrideWith(_TestConnection.new),
          gitServiceProvider.overrideWithValue(git),
          ...overrides,
        ],
      ),
    );
    addTearDown(controller.dispose);
    final tab = controller.newTab();
    (tab.container.read(connectionProvider.notifier) as _TestConnection).force(
      state,
    );
    TabsController.current = controller;
    return controller;
  }

  const connected = ConnectionState(
    phase: ConnectionPhase.connected,
    repoPath: '/srv/repo',
    repoPaths: ['/srv/repo'],
    connectionId: 'c1',
    connectionLabel: 'Prod',
    host: 'h',
  );

  /// The SSH half writes onto the `SavedConnection`; the This-Mac half writes
  /// to SharedPreferences. `NamespaceHistory` is the only thing that knows
  /// there are two stores, so the tests read through it rather than reaching
  /// into either.
  List<String> sshRecorded() => store.updated.isEmpty
      ? const []
      : store.updated.last.namespacesFor(
          namespaceHistoryKey(Forge.gitlab, 'gitlab.example'),
        );

  Future<List<String>> localRecorded() => NamespaceHistory(
    store,
  ).recent(forge: Forge.gitlab, host: 'gitlab.example');

  Future<Map<String, DateTime>> localTimes() => NamespaceHistory(
    store,
  ).recentTimes(forge: Forge.gitlab, host: 'gitlab.example');

  test(
    'a saved local repo is read offline and its namespace recorded',
    () async {
      final c = build(
        recents: [_local('l1', '/Users/me/app')],
        saved: [_saved('l1', '/Users/me/app')],
        localUrls: {
          '/resolved': 'https://gitlab.example/team/subgroup/app.git',
        },
      );
      addTearDown(c.dispose);

      await backfillNamespacesFromRecents(c, access: grants.access);

      expect(localExec.readPaths, ['/resolved']);
      expect(await localRecorded(), ['team/subgroup']);
      expect(
        (await localTimes())['team/subgroup'],
        DateTime.utc(2026, 8, 1),
        reason:
            'timed by the open it is evidence of, not by when the scan ran — '
            'otherwise a backfill ranks every stale repo above a fresh open',
      );
    },
  );

  test(
    'an SSH repo is read through the tab already holding its session',
    () async {
      final git = _OriginGit({
        '/srv/api': 'https://gitlab.example/platform/api.git',
      });
      tabsWith(connected, git);
      final c = build(recents: [_ssh('/srv/api')]);
      addTearDown(c.dispose);

      await backfillNamespacesFromRecents(c, access: grants.access);

      expect(git.asked, ['/srv/api']);
      expect(sshRecorded(), ['platform']);
    },
  );

  test('a host with no live session is skipped, and never dialled', () async {
    // The MADR's central limit. A disconnected tab must not be read, and no
    // connect may be attempted — the sheet cannot wait on a handshake.
    final git = _OriginGit({
      '/srv/api': 'https://gitlab.example/platform/api.git',
    });
    // The dropped tab keeps its connection identity — that is what a real
    // disconnected tab looks like. With `connectionId` left null the id guard
    // rejects it first and masks the `isConnected` check entirely, which is
    // exactly how the mutation `the SSH half dials a host with no live
    // session` survived its first run.
    tabsWith(const ConnectionState(connectionId: 'c1', host: 'h'), git);
    final c = build(recents: [_ssh('/srv/api')]);
    addTearDown(c.dispose);

    await backfillNamespacesFromRecents(c, access: grants.access);

    expect(git.asked, isEmpty, reason: 'no session means no read');
    expect(store.updated, isEmpty);
  });

  test('a tab on a different connection is not read', () async {
    final git = _OriginGit({
      '/srv/api': 'https://gitlab.example/platform/api.git',
    });
    tabsWith(connected, git); // connection c1
    final c = build(recents: [_ssh('/srv/api', id: 'c2')]);
    addTearDown(c.dispose);

    await backfillNamespacesFromRecents(c, access: grants.access);

    expect(git.asked, isEmpty);
    expect(store.updated, isEmpty);
  });

  test('with no tabs host at all, the SSH half reads nothing', () async {
    // Widget tests and secondary windows have no TabsController.current.
    final c = build(recents: [_ssh('/srv/api')]);
    addTearDown(c.dispose);

    await backfillNamespacesFromRecents(c, access: grants.access);

    expect(store.updated, isEmpty);
  });

  test('a grant already held is released when a later one throws', () async {
    // The throw has to come from `acquire`, not from the git read:
    // `GitService.originUrl` swallows every failure and answers null (Phase
    // 1), so a failing `git remote get-url` never reaches the `finally` at
    // all. Sabotaging the release with a read-side failure is why the mutation
    // `grants are not released when the read throws` survived its first run —
    // there was no throw to release against.
    final c = build(
      recents: [_local('l1', '/Users/me/wt')],
      saved: [_saved('l1', '/Users/me/wt', mainBookmark: 'main-bm')],
    );
    addTearDown(c.dispose);
    final released = <String>[];
    final access = ScopedAccess(
      startAccessing: (bookmark) async {
        if (bookmark == 'main-bm') throw const ProcessFailure();
        return '/resolved';
      },
      stopAccessing: (path) async => released.add(path),
    );

    await backfillNamespacesFromRecents(c, access: access);

    expect(released, [
      '/resolved',
    ], reason: 'a leaked refcount holds a native grant for the whole process');
  });

  test('a repo whose origin will not read simply records nothing', () async {
    // The ordinary failure: `git remote get-url` exits non-zero. It is not an
    // exception anywhere in this file's control flow — `originUrl` turns it
    // into null — so it is asserted as "records nothing", not as a throw.
    final c = build(
      recents: [_local('l1', '/Users/me/app')],
      saved: [_saved('l1', '/Users/me/app')],
    );
    addTearDown(c.dispose);

    await backfillNamespacesFromRecents(c, access: grants.access);

    expect(localExec.readPaths, ['/resolved']);
    expect(await localRecorded(), isEmpty);
    expect(grants.released, ['/resolved']);
  });

  test('a linked worktree acquires and releases both grants', () async {
    // `git remote get-url` in a linked worktree reads the main repo's .git,
    // so one grant is not enough to run it under the sandbox.
    final c = build(
      recents: [_local('l1', '/Users/me/wt')],
      saved: [_saved('l1', '/Users/me/wt', mainBookmark: 'main-bm')],
      localUrls: {'/resolved': 'https://gitlab.example/platform/wt.git'},
    );
    addTearDown(c.dispose);

    // Distinct resolved paths on purpose: ScopedAccess refcounts by *path*, so
    // two grants resolving to one path would end in a single native stop and
    // the release assertion would prove nothing.
    final acquired = <String>[];
    final released = <String>[];
    final access = ScopedAccess(
      startAccessing: (bookmark) async {
        acquired.add(bookmark);
        return bookmark == 'main-bm' ? '/resolved-main' : '/resolved';
      },
      stopAccessing: (path) async => released.add(path),
    );

    await backfillNamespacesFromRecents(c, access: access);

    expect(acquired, ['bm', 'main-bm']);
    expect(released, unorderedEquals(['/resolved', '/resolved-main']));
    expect(await localRecorded(), ['platform']);
  });

  test('a scoped work tree carries its GIT_DIR into the read', () async {
    // The dotfiles pattern: no `.git` to discover, so an unscoped read fails
    // with "not a git repository" and the namespace is silently never learned.
    final c = build(
      recents: [_local('l1', '/Users/me')],
      saved: [_saved('l1', '/Users/me', gitDir: '/Users/me/.home.git')],
      localUrls: {'/resolved': 'https://gitlab.example/platform/dots.git'},
    );
    addTearDown(c.dispose);

    await backfillNamespacesFromRecents(c, access: grants.access);

    expect(localExec.envs.single?['GIT_DIR'], '/Users/me/.home.git');
    expect(localExec.envs.single?['GIT_WORK_TREE'], '/resolved');
    expect(await localRecorded(), ['platform']);
  });

  test('a stale bookmark is skipped, not fatal', () async {
    final c = build(
      recents: [_local('l1', '/Users/me/gone'), _local('l2', '/Users/me/app')],
      saved: [_saved('l1', '/Users/me/gone'), _saved('l2', '/Users/me/app')],
      localUrls: {'/resolved': 'https://gitlab.example/platform/app.git'},
    );
    addTearDown(c.dispose);
    // A bookmark that no longer resolves — a moved or deleted folder.
    var first = true;
    final access = ScopedAccess(
      startAccessing: (bookmark) async {
        if (first) {
          first = false;
          return null;
        }
        return '/resolved';
      },
      stopAccessing: (_) async {},
    );

    await backfillNamespacesFromRecents(c, access: access);

    expect(await localRecorded(), [
      'platform',
    ], reason: 'the second repo is still scanned');
  });

  test('a repo that will not read does not stop the rest', () async {
    final git = _OriginGit({
      '/srv/api': 'https://gitlab.example/platform/api.git',
    });
    tabsWith(connected, git);
    final c = build(
      recents: [_local('l1', '/Users/me/broken'), _ssh('/srv/api')],
      saved: [_saved('l1', '/Users/me/broken')],
    );
    addTearDown(c.dispose);
    // A throw, not a failed command: a failed `git remote get-url` never
    // raises (see the note on the release test above), so it could not
    // exercise the loop's per-repository catch at all.
    final access = ScopedAccess(
      startAccessing: (_) async => throw const ProcessFailure(),
      stopAccessing: (_) async {},
    );

    await backfillNamespacesFromRecents(c, access: access);

    expect(sshRecorded(), ['platform']);
  });

  test('a namespace the account cannot create in is not recorded', () async {
    // Decision 1 applies to the scan exactly as it does to an open — the scan
    // records through the same method.
    final c = build(
      recents: [_local('l1', '/Users/me/app')],
      saved: [_saved('l1', '/Users/me/app')],
      localUrls: {'/resolved': 'https://gitlab.example/someone-else/app.git'},
    );
    addTearDown(c.dispose);

    await backfillNamespacesFromRecents(c, access: grants.access);

    expect(store.updated, isEmpty);
    expect(await localRecorded(), isEmpty);
  });

  test('running twice records the namespace once', () async {
    // Idempotent by construction — NamespaceHistory de-duplicates — which is
    // why there is no "already backfilled" flag to keep in sync.
    final c = build(
      recents: [_local('l1', '/Users/me/app')],
      saved: [_saved('l1', '/Users/me/app')],
      localUrls: {'/resolved': 'https://gitlab.example/team/subgroup/app.git'},
    );
    addTearDown(c.dispose);

    await backfillNamespacesFromRecents(c, access: grants.access);
    await backfillNamespacesFromRecents(c, access: grants.access);

    expect(await localRecorded(), ['team/subgroup']);
  });

  test('an empty recents list reads nothing at all', () async {
    final c = build();
    addTearDown(c.dispose);

    await backfillNamespacesFromRecents(c, access: grants.access);

    expect(grants.acquired, isEmpty);
    expect(localExec.readPaths, isEmpty);
  });

  test('a repo missing from the local store is skipped', () async {
    // The recents log outlives a removed bookmark; the id simply resolves to
    // nothing.
    final c = build(recents: [_local('gone', '/Users/me/app')]);
    addTearDown(c.dispose);

    await backfillNamespacesFromRecents(c, access: grants.access);

    expect(grants.acquired, isEmpty);
    expect(store.updated, isEmpty);
  });
}
