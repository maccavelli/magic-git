// The native History window's Dart shell: boot handshake (ready +
// requestState), session-driven rendering, repo-switch/disconnect handling,
// and the forwarded Recovery button. The executor seam is the same one
// production uses, so a fake executor stands in for the whole proxy.

import 'package:flutter/cupertino.dart' hide ConnectionState;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart' show MacosIcon;
import 'package:remote_magic_git/core/exec/exec_proxy_codec.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/features/history/history_view.dart';
import 'package:remote_magic_git/features/history/window/history_window_main.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _hub = MethodChannel('magicgit/history/hub');
const _codec = StandardMethodCodec();

/// Every command succeeds with empty output — enough for HistoryView to
/// render its "No commits" empty state, which proves the whole
/// provider-into-widget pipeline without fabricating git wire formats.
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

  late List<MethodCall> outgoing;

  /// Captures everything the shell sends over the hub; answers requestState
  /// with [initialState].
  void mockHub(ConnectionEventPayload? initialState) {
    messenger.setMockMethodCallHandler(_hub, (call) async {
      outgoing.add(call);
      if (call.method == 'requestState') return initialState?.encode();
      return null;
    });
  }

  /// Simulates a platform→Dart hub call (a pushed event from the relay).
  Future<void> pushHubEvent(String method, Object? arguments) async {
    await messenger.handlePlatformMessage(
      'magicgit/history/hub',
      _codec.encodeMethodCall(MethodCall(method, arguments)),
      (_) {},
    );
  }

  Future<void> pump(WidgetTester tester, _FakeExecutor executor) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeExecutorProvider.overrideWithValue(executor),
          recoveryVisibleProvider.overrideWith(
            ForwardingRecoveryVisibility.new,
          ),
        ],
        child: const HistoryWindowApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  setUp(() {
    outgoing = [];
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(_hub, null);
  });

  testWidgets('boots via ready + requestState and renders the history view', (
    tester,
  ) async {
    mockHub(_connected('/srv/repo'));
    final executor = _FakeExecutor();
    await pump(tester, executor);

    final methods = outgoing.map((c) => c.method).toList();
    expect(methods, contains('ready'), reason: 'reveals the native window');
    expect(methods, contains('requestState'));
    expect(
      outgoing.singleWhere((c) => c.method == 'setWindowTitle').arguments,
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
    mockHub(_connected('/srv/repo'));
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
    expect(outgoing.map((c) => c.method), isNot(contains('closeSelf')));
  });

  testWidgets('shows the waiting placeholder until a session arrives', (
    tester,
  ) async {
    mockHub(null); // requestState answered with nothing
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
    mockHub(_connected('/srv/repo'));
    final executor = _FakeExecutor();
    await pump(tester, executor);
    final callsBefore = executor.calls.length;

    await pushHubEvent('connectionChanged', _connected('/srv/other').encode());
    await tester.pumpAndSettle();

    expect(
      outgoing.last.arguments,
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
    mockHub(_connected('/srv/repo'));
    await pump(tester, _FakeExecutor());

    await pushHubEvent(
      'connectionChanged',
      const ConnectionEventPayload(
        phase: 'disconnected',
        backend: 'ssh',
      ).encode(),
    );
    await tester.pumpAndSettle();
    expect(outgoing.map((c) => c.method), contains('closeSelf'));
  });

  testWidgets('the Recovery button forwards to the main window instead of '
      'opening a local sheet', (tester) async {
    mockHub(_connected('/srv/repo'));
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

    expect(outgoing.map((c) => c.method), contains('openRecovery'));
    expect(find.text('Recovery'), findsNothing, reason: 'no local sheet');
  });
}
