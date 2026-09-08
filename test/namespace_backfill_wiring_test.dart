// MADR 0037 Phase 4 — the create sheet's namespace field runs the backfill
// scan when it mounts.
//
// Phase 3 proves what the scan reads and records; this file proves only the
// three things the wiring adds, because those are the ones that can break
// independently of it:
//
//  * it fires on mount, and the field renders WITHOUT waiting for it — the
//    wizard never waits on a suggestion (MADR 0032);
//  * what the scan learns shows up without reopening the sheet, which takes
//    an invalidate the scan itself cannot issue;
//  * a scan that fails leaves an ordinary, working text field behind.
//
// The SSH half is used throughout: it needs no security-scoped bookmark, so
// nothing here touches a platform channel that `testWidgets` cannot answer.

import 'dart:async';

import 'package:flutter/cupertino.dart'
    hide OverlayVisibilityMode, ConnectionState;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/exec/local_command_executor.dart';
import 'package:remote_magic_git/core/forge/forge.dart';
import 'package:remote_magic_git/core/forge/namespace_history.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/storage/recent_repos_store.dart';
import 'package:remote_magic_git/core/storage/saved_connection.dart';
import 'package:remote_magic_git/core/storage/saved_local_repo.dart';
import 'package:remote_magic_git/core/storage/store_bus.dart';
import 'package:remote_magic_git/features/common/tappable.dart';
import 'package:remote_magic_git/features/tabs/tabs_controller.dart';
import 'package:remote_magic_git/features/workspace/create_repo_steps/namespace_field.dart';
import 'package:riverpod/misc.dart' show Override;
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/app_scope.dart';
import 'helpers/create_repo_harness.dart'
    show FakeConnectionStore, FakeCreateExecutor, StubConnection, testConn;

/// The real [ConnectionStore] fires [StoreBus] on every write, and
/// `TabsController` turns that into a `savedConnectionsProvider` invalidate in
/// each tab's container — which is how a namespace written onto a connection
/// reaches the sheet, since the sheet runs against the ACTIVE TAB's container
/// (`tabs_host.dart:500-505`). The shared fake skips the notify, so this file
/// restores it rather than asserting against wiring the app does not have.
class _BusStore extends FakeConnectionStore {
  @override
  Future<void> updateMetadata(SavedConnection conn) async {
    await super.updateMetadata(conn);
    StoreBus.instance.notifyConnectionsChanged();
  }
}

/// `gh api user` then `gh api user/orgs` — the two calls a GitHub creatable
/// lookup makes. Everything else answers empty.
FakeCreateExecutor _ghExecutor(List<String> orgs) {
  final exec = FakeCreateExecutor();
  exec.respond = (args) {
    final joined = args.join(' ');
    if (joined.contains('user/orgs')) {
      return SSHCommandResult(
        exitCode: 0,
        stdout: '[${orgs.map((o) => '{"login":"$o"}').join(',')}]',
        stderr: '',
      );
    }
    if (joined.contains('api user')) {
      return const SSHCommandResult(
        exitCode: 0,
        stdout: '{"login":"me"}',
        stderr: '',
      );
    }
    return null;
  };
  return exec;
}

/// The This-Mac executor the local half of the scan reads through.
class _LocalExec extends LocalCommandExecutor {
  _LocalExec(this.url) {
    configureEnvironment(path: '/usr/bin', binaries: const {});
  }
  final String url;

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
  }) async => SSHCommandResult(exitCode: 0, stdout: '$url\n', stderr: '');
}

class _NoopGuard extends LocalEnvironmentGuard {
  _NoopGuard(super.ref);
  @override
  Future<void> ensure() async {}
}

/// The `GitService` of the tab that already holds the SSH session. Optionally
/// parks, so a test can hold the scan mid-flight, or throws.
class _TabGit extends GitService {
  _TabGit(this._url, {this.gate, this.fail = false})
    : super(FakeCreateExecutor());
  final String? _url;
  final Completer<void>? gate;
  final bool fail;
  int calls = 0;

  @override
  Future<String?> originUrl(String repoPath, {String remote = 'origin'}) async {
    calls++;
    if (gate != null) await gate!.future;
    if (fail) throw StateError('read failed');
    return _url;
  }
}

const _connected = ConnectionState(
  phase: ConnectionPhase.connected,
  repoPath: '/srv/repo',
  repoPaths: ['/srv/repo'],
  connectionId: 'c1',
  connectionLabel: 'Prod',
  host: 'h',
);

Finder _field() => find.byWidgetPredicate(
  (w) => w is MacosTextField && w.placeholder == 'Search namespaces…',
);

/// The dropdown's rows, in the order offered. Section headers are `Text` but
/// not rows, so this is scoped through `Tappable` as the sibling suite does.
List<String> _rows(WidgetTester tester) => tester
    .widgetList<Text>(
      find.descendant(
        of: find.descendant(
          of: find.byType(ListView),
          matching: find.byType(Tappable),
        ),
        matching: find.byType(Text),
      ),
    )
    .map((t) => t.data)
    .whereType<String>()
    .toList();

void main() {
  late _BusStore store;

  setUp(() => TabsController.current = null);
  tearDown(() => TabsController.current = null);

  /// Mounts a bare [NamespaceField] over a session on `c1`, with one SSH
  /// repository in the recents list and one tab already holding that session.
  ///
  /// `namespaceSuggestionsProvider` is deliberately NOT stubbed: the point is
  /// that the real provider picks up what the scan wrote, which a fixture
  /// would hide.
  Future<_TabGit> pumpField(
    WidgetTester tester, {
    required _TabGit tabGit,
    List<String> orgs = const ['me', 'learned-org', 'other-org'],
    List<RecentRepoRef> recents = const [],
    List<SavedLocalRepo> savedLocal = const [],
    String localUrl = '',
    String? connectionId = 'c1',
  }) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(900, 700));
    store = _BusStore();
    final exec = _ghExecutor(orgs);

    final tabs = TabsController(
      containerFactory: (List<Override> overrides) => ProviderContainer(
        overrides: [
          connectionProvider.overrideWith(() => StubConnection(_connected)),
          gitServiceProvider.overrideWithValue(tabGit),
          ...overrides,
        ],
      ),
    );
    addTearDown(tabs.dispose);
    tabs.newTab();
    TabsController.current = tabs;

    // An explicit container, then `UncontrolledProviderScope` over it — the
    // shape `TabsHost` uses for the active tab, and the only way to subscribe
    // it to the store bus the way `TabsController` does.
    final container = appProviderContainer(
      overrides: [
        connectionProvider.overrideWith(() => StubConnection(_connected)),
        // BOTH seams: the suggestion providers read `activeExecutorProvider`,
        // but `ConnectionController._activeExecutor` reads `executorProvider`
        // directly (app_providers.dart:1127-1130), and that is the one the
        // creatable check behind the recording goes through.
        activeExecutorProvider.overrideWithValue(exec),
        executorProvider.overrideWithValue(exec),
        connectionStoreProvider.overrideWithValue(store),
        // Reads back what the scan wrote, the way the real store would.
        savedConnectionsProvider.overrideWith(
          (ref) async => [
            store.updated.isEmpty ? testConn : store.updated.last,
          ],
        ),
        recentRepoRefsProvider.overrideWith((ref) async => recents),
        savedLocalReposProvider.overrideWith((ref) async => savedLocal),
        localExecutorProvider.overrideWithValue(_LocalExec(localUrl)),
        localEnvironmentProvider.overrideWith(_NoopGuard.new),
      ],
    );
    addTearDown(container.dispose);
    final sub = StoreBus.instance.onConnectionsChanged.listen(
      (_) => container.invalidate(savedConnectionsProvider),
    );
    addTearDown(sub.cancel);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MacosApp(
          debugShowCheckedModeBanner: false,
          home: MacosWindow(
            child: MacosScaffold(
              children: [
                ContentArea(
                  builder: (context, _) => NamespaceField(
                    forge: Forge.github,
                    host: 'github.com',
                    isLocalTarget: false,
                    connectionId: connectionId,
                    controller: TextEditingController(),
                    onChanged: () {},
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return tabGit;
  }

  RecentRepoRef sshRef(String path) => RecentRepoRef(
    isLocal: false,
    id: 'c1',
    repoPath: path,
    openedAt: DateTime.utc(2026, 8, 3),
  );

  testWidgets('the field renders on the first frame, scan still in flight', (
    tester,
  ) async {
    final gate = Completer<void>();
    final git = _TabGit('https://github.com/learned-org/app.git', gate: gate);
    await pumpField(tester, tabGit: git, recents: [sshRef('/srv/app')]);

    // One pump only — no settle. The scan is parked inside `originUrl`.
    await tester.pump();

    expect(_field(), findsOneWidget, reason: 'the field never waits on a scan');
    await tester.enterText(_field(), 'lea');
    await tester.pump();
    expect(
      (tester.widget(_field()) as MacosTextField).controller?.text,
      'lea',
      reason: 'and it is typeable while the scan is still running',
    );

    gate.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('the scan runs once on mount', (tester) async {
    final git = _TabGit('https://github.com/learned-org/app.git');
    await pumpField(tester, tabGit: git, recents: [sshRef('/srv/app')]);
    await tester.pumpAndSettle();

    expect(git.calls, 1);
  });

  testWidgets('a namespace the scan learns appears without reopening', (
    tester,
  ) async {
    // `learned-org` is in the creatable list either way, so its mere presence
    // proves nothing. What the scan buys is its promotion into RECENTLY
    // ACTIVE — the first section — which is what is asserted.
    final git = _TabGit('https://github.com/learned-org/app.git');
    await pumpField(tester, tabGit: git, recents: [sshRef('/srv/app')]);
    await tester.pumpAndSettle();

    await tester.tap(_field());
    await tester.pumpAndSettle();

    expect(
      store.updated.single.namespacesFor(
        namespaceHistoryKey(Forge.github, 'github.com'),
      ),
      ['learned-org'],
      reason: 'the scan recorded it onto the connection',
    );
    expect(
      _rows(tester).first,
      'learned-org',
      reason:
          'and the invalidate put it at the head of RECENTLY ACTIVE without '
          'the sheet being reopened',
    );
  });

  testWidgets('with nothing to learn, the list is the creatable list alone', (
    tester,
  ) async {
    // The control for the test above: same fixture, empty recents. Without it
    // that assertion would pass on ordering that owes nothing to the scan.
    final git = _TabGit('https://github.com/learned-org/app.git');
    await pumpField(tester, tabGit: git);
    await tester.pumpAndSettle();

    await tester.tap(_field());
    await tester.pumpAndSettle();

    expect(git.calls, 0, reason: 'no recents, nothing to read');
    expect(_rows(tester).first, 'me', reason: 'the account, first as always');
  });

  testWidgets('a This-Mac namespace appears, which needs the invalidate', (
    tester,
  ) async {
    // The SSH half does not need the explicit invalidate: its write lands on a
    // `SavedConnection`, the store bus refreshes `savedConnectionsProvider`,
    // and `namespaceSuggestionsProvider` WATCHES that — so it recomputes on
    // its own. This half is where the invalidate earns its place: a This-Mac
    // history is written straight to SharedPreferences, which the suggestion
    // provider reads inside its own body with nothing to watch. Without the
    // invalidate a learned namespace waits for the sheet to be reopened.
    //
    // The mutation `the suggestions are not invalidated when the scan
    // finishes` survived until this test existed, for exactly that reason.
    const bookmarks = MethodChannel('magicgit/bookmarks');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      bookmarks,
      (call) async =>
          call.method == 'startAccessingBookmark' ? '/Users/me/app' : null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        bookmarks,
        null,
      ),
    );

    await pumpField(
      tester,
      tabGit: _TabGit(null),
      connectionId: null, // a This-Mac history, not a connection's
      recents: [
        RecentRepoRef(
          isLocal: true,
          id: 'l1',
          repoPath: '/Users/me/app',
          openedAt: DateTime.utc(2026, 8, 3),
        ),
      ],
      savedLocal: const [
        SavedLocalRepo(
          id: 'l1',
          label: 'app',
          repoPath: '/Users/me/app',
          bookmarkData: 'bm',
        ),
      ],
      localUrl: 'https://github.com/learned-org/app.git',
    );
    await tester.pumpAndSettle();

    await tester.tap(_field());
    await tester.pumpAndSettle();

    expect(store.updated, isEmpty, reason: 'no connection to write onto');
    expect(_rows(tester).first, 'learned-org');
  });

  testWidgets('a scan that throws leaves an ordinary working field', (
    tester,
  ) async {
    final git = _TabGit(null, fail: true);
    await pumpField(tester, tabGit: git, recents: [sshRef('/srv/app')]);
    await tester.pumpAndSettle();

    await tester.enterText(_field(), 'learned');
    await tester.pumpAndSettle();

    expect(_rows(tester), ['learned-org']);
  });
}
