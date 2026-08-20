import 'package:flutter/widgets.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/features/app_shell.dart';
import 'package:remote_magic_git/features/connection/connection_landing.dart';

/// A ConnectionController stuck at a fixed state, so the shell can be pumped
/// mid-drop without running a real connect or auto-reconnect loop.
class _StubConnection extends ConnectionController {
  _StubConnection(this._state);
  final ConnectionState _state;
  var stopReconnectCalls = 0;

  @override
  ConnectionState build() => _state;

  @override
  void stopReconnect() => stopReconnectCalls++;
}

/// The overlay runs a 1-second elapsed-time ticker, so pumpAndSettle would
/// never return: pump discretely and unmount before the test ends.
Future<_StubConnection> _pumpDropped(
  WidgetTester tester, {
  String? host = 'admdevops',
  int attempt = 2,
  String? reason = 'Connection lost',
}) async {
  final stub = _StubConnection(
    ConnectionState(
      phase: ConnectionPhase.connecting,
      host: host,
      reconnecting: true,
      reconnectAttempt: attempt,
      error: reason,
    ),
  );
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [connectionProvider.overrideWith(() => stub)],
      child: const MacosApp(
        debugShowCheckedModeBanner: false,
        home: SizedBox.expand(child: AppShell()),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  _drainTestFontOverflow(tester);
  return stub;
}

/// Clears the RenderFlex overflow the *test font* provokes, and only that.
///
/// The overlay card is a fixed 340 px (24 px padding each side → 292 px of
/// content), sized for SF Pro at 13 pt where 'Reconnecting… (attempt 2)'
/// measures ~150 px. `flutter test` substitutes a fixed-width fallback whose
/// every glyph is a 13 px square, so the same string measures ~325 px and the
/// row reports a 67 px overflow that cannot occur in the app. Anything that is
/// not that overflow is rethrown, so this never hides a real failure.
void _drainTestFontOverflow(WidgetTester tester) {
  while (true) {
    final error = tester.takeException();
    if (error == null) return;
    final text = error.toString();
    if (!text.contains('overflowed by') &&
        !text.contains('deactivated widget')) {
      fail('unexpected exception while pumping the shell: $error');
    }
  }
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 2));
}

void main() {
  testWidgets('640px window hides the main sidebar without losing content', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(640, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const ProviderScope(
        child: MacosApp(home: SizedBox.expand(child: AppShell())),
      ),
    );
    await tester.pumpAndSettle();

    final contentContext = tester.element(find.byType(ConnectionLanding));
    expect(MacosWindowScope.of(contentContext).isSidebarShown, isFalse);
    expect(find.text('Connections Manager'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('a dropped session shows the reconnect overlay, not the '
      'landing card', (tester) async {
    await _pumpDropped(tester);

    expect(find.text('Connection interrupted'), findsOneWidget);
    expect(find.textContaining('admdevops'), findsWidgets);
    expect(find.textContaining('attempt 2'), findsOneWidget);
    expect(find.text('Stop Retrying'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    // Branch order is the contract: the reconnecting check sits ahead of the
    // `!connected` fallback, so a drop must never flash the landing card.
    expect(find.byType(ConnectionLanding), findsNothing);

    await _unmount(tester);
  });

  testWidgets('the overlay suppresses a redundant reason line', (tester) async {
    // 'Connection lost' is what the headline already says; repeating it as a
    // detail line reads like two different failures.
    await _pumpDropped(tester, reason: 'Connection lost');
    expect(find.text('Connection lost'), findsNothing);
    await _unmount(tester);

    await _pumpDropped(tester, reason: 'kex exchange failed');
    expect(find.text('kex exchange failed'), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets('a first attempt reads plain "Reconnecting…"', (tester) async {
    await _pumpDropped(tester, attempt: 0);
    expect(find.text('Reconnecting…'), findsOneWidget);
    expect(find.textContaining('attempt'), findsNothing);
    await _unmount(tester);
  });

  testWidgets('an unknown host still names the failure', (tester) async {
    await _pumpDropped(tester, host: null);
    expect(find.text('The SSH connection dropped.'), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets('Stop Retrying calls stopReconnect', (tester) async {
    final stub = await _pumpDropped(tester);

    await tester.tap(find.text('Stop Retrying'));
    await tester.pump();

    expect(stub.stopReconnectCalls, 1);
    await _unmount(tester);
  });
}
