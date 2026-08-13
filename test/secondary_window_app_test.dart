// A native secondary window's Dart shell: boot handshake (ready +
// requestState), session-driven rendering, repo-switch/disconnect handling, and
// the locally-opened Recovery sheet + forwarded ⌘Z undo. The executor seam is
// the same one production uses, so a fake executor stands in for the whole
// proxy. Native per-window ops (ready/setWindowTitle/closeSelf) travel over the
// per-engine bootstrap channel; relayed traffic over the per-window hub.

import 'package:flutter/cupertino.dart' hide ConnectionState;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart' show MacosIcon;
import 'package:remote_magic_git/core/exec/exec_proxy_codec.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/git/watch_event.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/settings/app_settings.dart';
import 'package:remote_magic_git/core/settings/pane_layout.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/utils/git_porcelain_parser.dart';
import 'package:remote_magic_git/core/window/window_channels.dart';
import 'package:remote_magic_git/features/history/history_view.dart';
import 'package:remote_magic_git/features/history/ref_chip.dart';
import 'package:remote_magic_git/features/window/secondary_window_main.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _windowId = '7';
final _hub = MethodChannel(windowHubChannel(_windowId));
const _bootstrap = MethodChannel(windowBootstrapChannel);
const _codec = StandardMethodCodec();

const _descriptor = WindowDescriptor(windowId: _windowId, kind: 'history');

/// Every command succeeds with empty output — enough for HistoryView to render
/// its "No commits" empty state, which proves the whole provider-into-widget
/// pipeline without fabricating git wire formats.
class _FakeExecutor extends SSHCommandExecutor {
  final List<List<String>> calls = [];
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
    OperationDescriptor? operation,
    OperationEventCallback? onOperationEvent,
  }) async {
    calls.add(gitArgs);
    return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }
}

/// A GitService that serves one canned commit — enough for the actions-menu
/// test, which needs a selectable row (the executor-level fake can't produce
/// git's log wire format).
class _FakeGit extends GitService {
  _FakeGit({this.withRefs = false})
    : super(SSHCommandExecutor(SSHClientManager()));

  /// When true, decorate the head commit with a local HEAD branch + a tag —
  /// enough to prove the history pop-out paints ref chips.
  final bool withRefs;

  static const headHash = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

  static const headCommit = GitCommit(
    hash: headHash,
    shortHash: 'aaaaaaa',
    authorName: 'Dev',
    authorEmail: 'd@e',
    date: '2026-07-04T10:00',
    parents: [],
    subject: 'head commit',
  );

  static const headBranch = GitRef(
    name: 'refs/heads/master',
    oid: headHash,
    isHead: true,
    subject: 'head commit',
  );

  static const releaseTag = GitRef(
    name: 'refs/tags/v1.0.0',
    oid: headHash,
    isHead: false,
    subject: 'release',
  );

  @override
  Future<List<GitCommit>> log(
    String repoPath, {
    String revision = 'HEAD',
    int maxCount = 200,
    int skip = 0,
    String? grep,
    String? author,
    String? since,
    String? until,
    String? path,
    String? pathQuery,
    String? sha,
    bool all = false,
    bool follow = false,
    bool noMerges = false,
    bool fullHistory = false,
  }) async => const [headCommit];

  @override
  Future<List<GitRef>> refs(String repoPath) async =>
      withRefs ? const [headBranch, releaseTag] : const [];

  @override
  Future<String> showCommit(
    String repoPath,
    String hash, {
    String? path,
    int? context,
  }) async => 'diff --git a/x b/x\n@@ -1 +1 @@\n-a\n+b';
}

/// A [_FakeGit] whose status carries a controllable HEAD oid, and which counts
/// its log walks — the probe test's two observables.
class _HeadMoveGit extends _FakeGit {
  String currentOid = 'a' * 40;
  int logCalls = 0;

  @override
  Future<GitStatus> status(String repoPath) async => GitStatus(
    branch: GitBranchInfo(oid: currentOid, head: 'main'),
    files: const [],
  );

  @override
  Future<List<GitCommit>> log(
    String repoPath, {
    String revision = 'HEAD',
    int maxCount = 200,
    int skip = 0,
    String? grep,
    String? author,
    String? since,
    String? until,
    String? path,
    String? pathQuery,
    String? sha,
    bool all = false,
    bool follow = false,
    bool noMerges = false,
    bool fullHistory = false,
  }) async {
    logCalls++;
    return const [_FakeGit.headCommit];
  }
}

ConnectionEventPayload _connected(String repoPath) => ConnectionEventPayload(
  phase: 'connected',
  backend: 'ssh',
  repoPath: repoPath,
  connectionLabel: 'Prod',
  host: 'bastion',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  // Native per-window ops the shell fires over the bootstrap channel.
  late List<MethodCall> native;
  // Relayed calls the shell makes over the hub.
  late List<MethodCall> hubOut;

  /// Answers the hub's requestState with [initialState]; captures the rest.
  void mockChannels(ConnectionEventPayload? initialState) {
    messenger.setMockMethodCallHandler(_bootstrap, (call) async {
      native.add(call);
      return null;
    });
    messenger.setMockMethodCallHandler(_hub, (call) async {
      hubOut.add(call);
      if (call.method == 'requestState') return initialState?.encode();
      return null;
    });
  }

  /// Simulates a platform→Dart hub call (a pushed event from the relay).
  Future<void> pushHubEvent(String method, Object? arguments) async {
    await messenger.handlePlatformMessage(
      windowHubChannel(_windowId),
      _codec.encodeMethodCall(MethodCall(method, arguments)),
      (_) {},
    );
  }

  Future<void> pump(
    WidgetTester tester,
    _FakeExecutor executor, {
    GitService? gitService,
  }) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeExecutorProvider.overrideWithValue(executor),
          if (gitService != null)
            gitServiceProvider.overrideWithValue(gitService),
          // Empty watch stream — production would start fswatch/inotify and a
          // restart Timer on failure, which stays pending in fake-async and
          // trips the binding invariant at teardown.
          repoWatchProvider.overrideWith(
            (ref, repoPath) => const Stream<RepoWatchEvent>.empty(),
          ),
        ],
        child: SecondaryWindowApp(descriptor: _descriptor, hub: _hub),
      ),
    );
    await tester.pumpAndSettle();
    // Drain any residual lane/watch timers from real git/exec paths.
    addTearDown(() async {
      await tester.pump(const Duration(minutes: 2));
    });
  }

  setUp(() {
    native = [];
    hubOut = [];
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(_bootstrap, null);
    messenger.setMockMethodCallHandler(_hub, null);
  });

  testWidgets('boots via ready + requestState and renders the history view', (
    tester,
  ) async {
    mockChannels(_connected('/srv/repo'));
    final executor = _FakeExecutor();
    await pump(tester, executor);

    expect(
      native.map((c) => c.method),
      contains('ready'),
      reason: 'reveals the native window',
    );
    expect(hubOut.map((c) => c.method), contains('requestState'));
    expect(
      native.singleWhere((c) => c.method == 'setWindowTitle').arguments,
      'History — repo (Prod)',
    );
    expect(find.byType(HistoryView), findsOneWidget);
    expect(find.text('No commits'), findsOneWidget);
    expect(executor.calls, isNotEmpty, reason: 'log/refs fetched via the seam');
    expect(
      find.byWidgetPredicate(
        (w) => w is MacosIcon && w.icon == CupertinoIcons.macwindow,
      ),
      findsNothing,
      reason: 'no popout-from-popout button in the native window',
    );
  });

  testWidgets('a lost connection shows a banner over the (frozen) history', (
    tester,
  ) async {
    mockChannels(_connected('/srv/repo'));
    await pump(tester, _FakeExecutor());

    await pushHubEvent(
      'connectionChanged',
      const ConnectionEventPayload(
        phase: 'lost',
        backend: 'ssh',
        repoPath: '/srv/repo',
      ).encode(),
    );
    await tester.pumpAndSettle();

    expect(
      find.byType(HistoryView),
      findsOneWidget,
      reason: 'frozen-but-readable beats a blank window',
    );
    expect(find.textContaining('Connection lost'), findsOneWidget);
    expect(native.map((c) => c.method), isNot(contains('closeSelf')));
  });

  testWidgets('shows the waiting placeholder until a session arrives', (
    tester,
  ) async {
    mockChannels(null); // requestState answered with nothing
    await pump(tester, _FakeExecutor());
    expect(find.byType(HistoryView), findsNothing);
    expect(find.text('Waiting for session…'), findsOneWidget);

    await pushHubEvent('connectionChanged', _connected('/srv/repo').encode());
    await tester.pumpAndSettle();
    expect(find.byType(HistoryView), findsOneWidget);
  });

  testWidgets('a repo switch re-targets the view and retitles the window', (
    tester,
  ) async {
    mockChannels(_connected('/srv/repo'));
    final executor = _FakeExecutor();
    await pump(tester, executor);
    final callsBefore = executor.calls.length;

    await pushHubEvent('connectionChanged', _connected('/srv/other').encode());
    await tester.pumpAndSettle();

    expect(
      native.last.arguments,
      'History — other (Prod)',
      reason: 'title follows the active repo',
    );
    expect(
      executor.calls.length,
      greaterThan(callsBefore),
      reason: 'invalidation refetched for the new repo',
    );
    expect(find.byType(HistoryView), findsOneWidget);
  });

  testWidgets('disconnect asks the native side to close the window', (
    tester,
  ) async {
    mockChannels(_connected('/srv/repo'));
    await pump(tester, _FakeExecutor());

    await pushHubEvent(
      'connectionChanged',
      const ConnectionEventPayload(
        phase: 'disconnected',
        backend: 'ssh',
      ).encode(),
    );
    await tester.pumpAndSettle();
    expect(native.map((c) => c.method), contains('closeSelf'));
  });

  testWidgets('the commit actions menu opens inside the window shell', (
    tester,
  ) async {
    mockChannels(_connected('/srv/repo'));
    await pump(tester, _FakeExecutor(), gitService: _FakeGit());

    await tester.tap(find.text('head commit'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is MacosIcon && w.icon == CupertinoIcons.line_horizontal_3,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Checkout aaaaaaa'), findsOneWidget);
    expect(find.text('Cherry-pick aaaaaaa'), findsOneWidget);
  });

  testWidgets('a repoTick that echoes our own mutation is suppressed', (
    tester,
  ) async {
    mockChannels(_connected('/srv/repo'));
    final executor = _FakeExecutor();
    await pump(tester, executor);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SecondaryWindowShell)),
    );

    container.read(ownMutationTrackerProvider).mark('/srv/repo');
    final before = executor.calls.length;
    await pushHubEvent('repoTick', {
      'repoPath': '/srv/repo',
      'mode': 'eventDriven',
      'atMs': DateTime.now().millisecondsSinceEpoch,
    });
    await tester.pumpAndSettle();
    expect(executor.calls.length, before, reason: 'own echo → no refetch');

    // A git-state tick well outside the suppression window refreshes.
    // Unscoped (no paths) counts as "anything may have moved".
    await pushHubEvent('repoTick', {
      'repoPath': '/srv/repo',
      'mode': 'eventDriven',
      'atMs': DateTime.now()
          .add(const Duration(seconds: 10))
          .millisecondsSinceEpoch,
    });
    await tester.pumpAndSettle();
    expect(executor.calls.length, greaterThan(before));
  });

  testWidgets('polling ticks catch an external HEAD move in a History window', (
    tester,
  ) async {
    // In polling mode a tick carries no git-state signal, and the History
    // shell used to drop it outright — an external (or main-window) commit
    // never reached the pop-out while the watcher was degraded. The probe
    // refetches status per polling tick; a HEAD move between two landed
    // statuses refreshes the families exactly once.
    mockChannels(_connected('/srv/repo'));
    final git = _HeadMoveGit();
    await pump(tester, _FakeExecutor(), gitService: git);

    Future<void> pollTick() async {
      await pushHubEvent('repoTick', {
        'repoPath': '/srv/repo',
        'mode': 'polling',
        'atMs': DateTime.now()
            .add(const Duration(seconds: 10))
            .millisecondsSinceEpoch,
      });
      await tester.pumpAndSettle();
    }

    await pollTick(); // arms the probe, lands the baseline status
    final walksBefore = git.logCalls;

    git.currentOid = 'b' * 40; // an external commit moved HEAD
    await pollTick();
    expect(
      git.logCalls,
      greaterThan(walksBefore),
      reason: 'the HEAD move refreshed the mutation families',
    );

    final walksAfter = git.logCalls;
    await pollTick(); // same oid again — quiet
    expect(
      git.logCalls,
      walksAfter,
      reason: 'no move, no refresh — polling must not stampede the walk',
    );
  });

  testWidgets(
    'a working-tree-only tick does not re-walk history/refs in a History window',
    (tester) async {
      mockChannels(_connected('/srv/repo'));
      final executor = _FakeExecutor();
      await pump(tester, executor);
      final before = executor.calls.length;

      await pushHubEvent('repoTick', {
        'repoPath': '/srv/repo',
        'mode': 'eventDriven',
        'paths': ['lib/foo.dart'],
        'atMs': DateTime.now()
            .add(const Duration(seconds: 10))
            .millisecondsSinceEpoch,
      });
      await tester.pumpAndSettle();
      expect(
        executor.calls.length,
        before,
        reason: 'pure file edit must not invalidate log/refs for History',
      );
    },
  );

  testWidgets('history pop-out paints branch and tag ref chips', (
    tester,
  ) async {
    mockChannels(_connected('/srv/repo'));
    await pump(tester, _FakeExecutor(), gitService: _FakeGit(withRefs: true));

    expect(find.text('head commit'), findsOneWidget);
    expect(find.byType(RefChip), findsNWidgets(2));
    expect(find.text('master'), findsOneWidget);
    expect(find.text('v1.0.0'), findsOneWidget);
  });

  testWidgets('the Recovery button opens the sheet locally in this window', (
    tester,
  ) async {
    mockChannels(_connected('/srv/repo'));
    await pump(tester, _FakeExecutor());

    await tester.tap(
      // ToolIconButton renders a MacosIcon, which find.byIcon can't see.
      find.byWidgetPredicate(
        (w) =>
            w is MacosIcon &&
            w.icon == CupertinoIcons.arrow_counterclockwise_circle,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Recovery'), findsWidgets, reason: 'local sheet opened');
    expect(hubOut.map((c) => c.method), isNot(contains('openRecovery')));
  });

  testWidgets(
    'dragging the History divider in the pop-out notifies the main window '
    'via settingsChanged (debounced)',
    (tester) async {
      mockChannels(_connected('/srv/repo'));
      await pump(tester, _FakeExecutor());
      hubOut.clear();

      // The divider sits at the commit list's right edge (historyList default).
      final gesture = await tester.startGesture(
        const Offset(420.5, 300),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await gesture.moveBy(const Offset(15, 0));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(
        hubOut.map((c) => c.method),
        isNot(contains('settingsChanged')),
        reason: 'debounced — nothing before the 600ms window',
      );
      await tester.pump(const Duration(milliseconds: 700));
      expect(
        hubOut.map((c) => c.method),
        contains('settingsChanged'),
        reason: 'the pane width is part of the sync signature',
      );
    },
  );

  test(
    'the settings-sync signature covers zoom, wrap, and every pane width',
    () {
      // The signature is what the pop-out's settings listener selects on — a
      // locally-editable setting it misses is a setting whose pop-out edits
      // never reach the main window. Exhaustive over PaneId.values by
      // construction; this pins that each field actually moves the record.
      const base = AppSettings();
      expect(
        secondarySettingsSyncSignature(base),
        secondarySettingsSyncSignature(const AppSettings()),
        reason:
            'value-equal settings must produce an equal record (no ping-pong)',
      );
      expect(
        secondarySettingsSyncSignature(base.copyWith(historyZoom: 1.3)),
        isNot(secondarySettingsSyncSignature(base)),
      );
      expect(
        secondarySettingsSyncSignature(base.copyWith(historyDiffWrap: true)),
        isNot(secondarySettingsSyncSignature(base)),
      );
      for (final id in PaneId.values) {
        expect(
          secondarySettingsSyncSignature(
            base.copyWith(paneWidths: {id: paneSpecs[id]!.min}),
          ),
          isNot(secondarySettingsSyncSignature(base)),
          reason: 'a ${id.name} width change must move the signature',
        );
      }
    },
  );

  testWidgets('⌘Z asks the main isolate to undo and toasts the outcome', (
    tester,
  ) async {
    mockChannels(_connected('/srv/repo'));
    messenger.setMockMethodCallHandler(_hub, (call) async {
      hubOut.add(call);
      if (call.method == 'requestState') {
        return _connected('/srv/repo').encode();
      }
      if (call.method == 'performUndo') {
        return {'status': 'done', 'description': 'Cherry-pick abc1234'};
      }
      return null;
    });
    await pump(tester, _FakeExecutor());

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();

    final undoCall = hubOut.singleWhere((c) => c.method == 'performUndo');
    expect((undoCall.arguments as Map)['repoPath'], '/srv/repo');
    expect(find.text('Undid: Cherry-pick abc1234'), findsOneWidget);
  });
}
