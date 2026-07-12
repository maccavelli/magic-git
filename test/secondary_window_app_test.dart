// A native secondary window's Dart shell: boot handshake (ready +
// requestState), session-driven rendering, repo-switch/disconnect handling, and
// the locally-opened Recovery sheet + forwarded ⌘Z undo. The executor seam is
// the same one production uses, so a fake executor stands in for the whole
// proxy. Native per-window ops (ready/setWindowTitle/closeSelf) travel over the
// per-engine bootstrap channel; relayed traffic over the per-window hub.

import 'package:flutter/cupertino.dart' hide ConnectionState;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart' show MacosIcon;
import 'package:remote_magic_git/core/exec/exec_proxy_codec.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/window/window_channels.dart';
import 'package:remote_magic_git/features/history/history_view.dart';
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
  }) async {
    calls.add(gitArgs);
    return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }
}

/// A GitService that serves one canned commit — enough for the actions-menu
/// test, which needs a selectable row (the executor-level fake can't produce
/// git's log wire format).
class _FakeGit extends GitService {
  _FakeGit() : super(SSHCommandExecutor(SSHClientManager()));

  static const headCommit = GitCommit(
    hash: 'aaaaaaa1111111',
    shortHash: 'aaaaaaa',
    authorName: 'Dev',
    authorEmail: 'd@e',
    date: '2026-07-04T10:00',
    parents: [],
    subject: 'head commit',
  );

  @override
  Future<List<GitCommit>> log(
    String repoPath, {
    String revision = 'HEAD',
    int maxCount = 200,
    String? grep,
    String? author,
    String? since,
    String? until,
    String? path,
    bool all = false,
    bool follow = false,
    bool noMerges = false,
  }) async => const [headCommit];

  @override
  Future<List<GitRef>> refs(String repoPath) async => const [];

  @override
  Future<String> showCommit(String repoPath, String hash, {String? path}) async =>
      'diff --git a/x b/x\n@@ -1 +1 @@\n-a\n+b';
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
        ],
        child: SecondaryWindowApp(descriptor: _descriptor, hub: _hub),
      ),
    );
    await tester.pumpAndSettle();
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

    expect(native.map((c) => c.method), contains('ready'),
        reason: 'reveals the native window');
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

  testWidgets('a lost connection shows a banner over the (frozen) history',
      (tester) async {
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

    expect(find.byType(HistoryView), findsOneWidget,
        reason: 'frozen-but-readable beats a blank window');
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
    expect(executor.calls.length, greaterThan(callsBefore),
        reason: 'invalidation refetched for the new repo');
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

    // A tick well outside the suppression window refreshes normally.
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

  testWidgets('⌘Z asks the main isolate to undo and toasts the outcome', (
    tester,
  ) async {
    mockChannels(_connected('/srv/repo'));
    messenger.setMockMethodCallHandler(_hub, (call) async {
      hubOut.add(call);
      if (call.method == 'requestState') return _connected('/srv/repo').encode();
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
