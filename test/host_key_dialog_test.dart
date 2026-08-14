// The host-key dialog's dismissal contract, end to end through AppShell.
//
// `_verifyHostKey` parks the whole connect on a Completer that only
// accept/reject completes. Any pop that isn't a button press — the shell's own
// listener popping when the prompt clears elsewhere, a route teardown, a
// future disconnect path — used to leave that future unresolved forever: a
// silent, unrecoverable hang with no error surfaced and no way to re-show the
// dialog (the listener's `previous == null` guard blocks it while
// `hostKeyPrompt` stays non-null). These tests assert the connect always
// *resolves*, because the failure mode is a hang rather than a wrong value.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/storage/known_hosts_store.dart';
import 'package:remote_magic_git/features/app_shell.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _VerifyingManager extends SSHClientManager {
  String keyType = 'ssh-ed25519';
  List<int> fingerprintBytes = utf8.encode('SHA256:NEWNEWNEWNEWNEWNEWNE');
  final Completer<void> _done = Completer<void>();

  @override
  Future<void> connect(
    SSHConnectionProfile profile, {
    FutureOr<bool> Function(String type, Uint8List fingerprint)?
    onVerifyHostKey,
    void Function(Duration rtt)? onPingSample,
  }) async {
    if (onVerifyHostKey != null) {
      final accepted = await onVerifyHostKey(
        keyType,
        Uint8List.fromList(fingerprintBytes),
      );
      if (!accepted) {
        throw Exception('Hostkey verification failed');
      }
    }
  }

  @override
  Future<void>? get done => _done.future;

  @override
  Future<void> disconnect() async {}
}

class _NoopExecutor extends SSHCommandExecutor {
  _NoopExecutor() : super(SSHClientManager());

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
    return const SSHCommandResult(exitCode: 0, stdout: 'true\n', stderr: '');
  }
}

void main() {
  const profile = SSHConnectionProfile(host: 'h', port: 22, username: 'u');

  /// `pumpAndSettle` never returns here: the connecting phase renders an
  /// indeterminate spinner, so frames are scheduled forever. Pump a bounded
  /// number of frames instead.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<ProviderContainer> pumpShell(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final manager = _VerifyingManager();
    final container = ProviderContainer(
      overrides: [
        sshClientManagerProvider.overrideWithValue(manager),
        gitServiceProvider.overrideWithValue(GitService(_NoopExecutor())),
      ],
    );
    addTearDown(container.dispose);

    // A previously trusted key, so the new one is a *mismatch* and prompts.
    await container
        .read(knownHostsStoreProvider)
        .remember(
          'h',
          22,
          const KnownHostEntry(
            keyType: 'ssh-ed25519',
            fingerprint: 'SHA256:OLDOLDOLDOLDOLDOLDOL',
          ),
        );

    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MacosApp(
          debugShowCheckedModeBanner: false,
          home: SizedBox.expand(child: AppShell()),
        ),
      ),
    );
    await settle(tester);
    return container;
  }

  testWidgets('popping the dialog without a decision resolves the connect '
      'instead of hanging forever', (tester) async {
    final container = await pumpShell(tester);
    final controller = container.read(connectionProvider.notifier);

    var resolved = false;
    unawaited(
      controller
          .connect(profile: profile, repoPath: '/repo')
          .then((_) => resolved = true),
    );
    await settle(tester);

    expect(find.text('Host Key Changed'), findsOneWidget);

    // Pop the route the way a teardown would — no button press at all.
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await settle(tester);

    expect(find.text('Host Key Changed'), findsNothing);
    expect(
      resolved,
      isTrue,
      reason: 'the connect must fail closed, not park on an unresolved '
          'host-key decision',
    );
    expect(container.read(connectionProvider).hostKeyPrompt, isNull);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('the trusted key survives a dismissal — failing closed must not '
      'silently adopt the new key', (tester) async {
    final container = await pumpShell(tester);
    final controller = container.read(connectionProvider.notifier);

    unawaited(controller.connect(profile: profile, repoPath: '/repo'));
    await settle(tester);
    expect(find.text('Host Key Changed'), findsOneWidget);

    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await settle(tester);

    final stored = await container
        .read(knownHostsStoreProvider)
        .lookup('h', 22);
    expect(stored!.fingerprint, 'SHA256:OLDOLDOLDOLDOLDOLDOL');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  // The accept path is deliberately NOT covered here. Tapping "Refresh Key and
  // Continue" lets the connect run to completion, which starts the session's
  // periodic work and leaves timers the test binding rejects. It is already
  // covered where it belongs — at the notifier level, in
  // host_key_verification_test.dart ('acceptHostKeyChange lets the connection
  // proceed and remembers the new key', plus 'accepting then a stray reject
  // does not flip the decision', which pins the interaction with the
  // fail-closed dismissal handler these tests exercise).
}
