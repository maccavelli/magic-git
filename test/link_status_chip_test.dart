// SshLinkStatusRow / connection-status mapping: pure status helper + widget
// smoke for local hide, Connected with/without latency samples, and the
// reconnecting / disconnected labels.

import 'package:flutter/widgets.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/features/common/link_status_chip.dart';

class _StubConnection extends ConnectionController {
  _StubConnection(this._state);
  final ConnectionState _state;
  @override
  ConnectionState build() => _state;
}

class _StubPingSamples extends PingSamplesNotifier {
  _StubPingSamples(this._samples);
  final List<Duration> _samples;
  @override
  List<Duration> build() => _samples;
}

void main() {
  group('sshUiConnectionStatus', () {
    test('local sessions map to null', () {
      expect(
        sshUiConnectionStatus(
          const ConnectionState(
            phase: ConnectionPhase.connected,
            backend: ConnectionBackend.local,
            repoPath: '/tmp/repo',
          ),
        ),
        isNull,
      );
    });

    test('SSH connected → connected', () {
      expect(
        sshUiConnectionStatus(
          const ConnectionState(
            phase: ConnectionPhase.connected,
            host: 'box',
          ),
        ),
        SshUiConnectionStatus.connected,
      );
    });

    test('reconnecting flag → reconnecting', () {
      expect(
        sshUiConnectionStatus(
          const ConnectionState(
            phase: ConnectionPhase.connecting,
            reconnecting: true,
            host: 'box',
            reconnectAttempt: 2,
          ),
        ),
        SshUiConnectionStatus.reconnecting,
      );
    });

    test('phase lost → reconnecting', () {
      expect(
        sshUiConnectionStatus(
          const ConnectionState(
            phase: ConnectionPhase.lost,
            host: 'box',
          ),
        ),
        SshUiConnectionStatus.reconnecting,
      );
    });

    test('disconnected / error → disconnected', () {
      expect(
        sshUiConnectionStatus(
          const ConnectionState(phase: ConnectionPhase.disconnected),
        ),
        SshUiConnectionStatus.disconnected,
      );
      expect(
        sshUiConnectionStatus(
          const ConnectionState(
            phase: ConnectionPhase.error,
            error: 'boom',
          ),
        ),
        SshUiConnectionStatus.disconnected,
      );
    });
  });

  group('SshLinkStatusRow', () {
    Future<void> pumpRow(
      WidgetTester tester, {
      required ConnectionState connection,
      List<Duration> samples = const [],
    }) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            connectionProvider.overrideWith(() => _StubConnection(connection)),
            pingSamplesProvider.overrideWith(
              () => _StubPingSamples(samples),
            ),
          ],
          child: MacosApp(
            home: MacosWindow(
              child: const ContentArea(
                builder: _content,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('local session renders nothing', (tester) async {
      await pumpRow(
        tester,
        connection: const ConnectionState(
          phase: ConnectionPhase.connected,
          backend: ConnectionBackend.local,
          repoPath: '/tmp/repo',
        ),
      );
      expect(find.text('Connected'), findsNothing);
      expect(find.textContaining('ms'), findsNothing);
    });

    testWidgets('SSH connected without samples shows Connected only', (
      tester,
    ) async {
      await pumpRow(
        tester,
        connection: const ConnectionState(
          phase: ConnectionPhase.connected,
          host: 'admdevops',
          repoPath: '/srv/repo',
        ),
      );
      expect(find.text('Connected'), findsOneWidget);
      expect(find.textContaining('ms'), findsNothing);
    });

    testWidgets('SSH connected with samples shows latency + Connected', (
      tester,
    ) async {
      await pumpRow(
        tester,
        connection: const ConnectionState(
          phase: ConnectionPhase.connected,
          host: 'admdevops',
          repoPath: '/srv/repo',
        ),
        samples: const [
          Duration(milliseconds: 40),
          Duration(milliseconds: 50),
          Duration(milliseconds: 60),
        ],
      );
      expect(find.text('Connected'), findsOneWidget);
      // Median of 40/50/60 is 50.
      expect(find.text('50 ms'), findsOneWidget);
    });

    testWidgets('reconnecting shows Reconnecting', (tester) async {
      await pumpRow(
        tester,
        connection: const ConnectionState(
          phase: ConnectionPhase.lost,
          reconnecting: true,
          host: 'admdevops',
          reconnectAttempt: 1,
        ),
      );
      expect(find.text('Reconnecting'), findsOneWidget);
      expect(find.text('Connected'), findsNothing);
    });

    testWidgets('disconnected shows Disconnected', (tester) async {
      await pumpRow(
        tester,
        connection: const ConnectionState(
          phase: ConnectionPhase.disconnected,
          host: 'admdevops',
        ),
      );
      expect(find.text('Disconnected'), findsOneWidget);
    });
  });
}

Widget _content(BuildContext context, ScrollController controller) {
  return const Center(child: SshLinkStatusRow());
}
