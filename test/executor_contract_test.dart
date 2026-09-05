// MADR 0030 T1.1. One test body, run against every `CommandExecutor`
// implementation that can be constructed in-process.
//
// `AGENTS.md` calls this seam the load-bearing abstraction. It has five
// implementations, and the tests naming them ranged from 126 files
// (`SSHCommandExecutor`) to 1 (`ProxyCommandExecutor`, which every pop-out
// window uses). Shape C — parity — produced a real defect in the watch
// services; this asserts the executor seam does not have the same hole.
//
// Where an implementation deliberately does NOT satisfy a row, the harness
// asserts **the documented refusal**. That is parity too: a difference that is
// intentional and pinned, rather than a difference nobody noticed.

import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/exec/activity_command_executor.dart';
import 'package:remote_magic_git/core/exec/exec_proxy_codec.dart';
import 'package:remote_magic_git/core/exec/proxy_command_executor.dart';
import 'package:remote_magic_git/core/exec/scoped_command_executor.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

/// Records exactly what a wrapper hands to the executor beneath it.
class _Recording extends SSHCommandExecutor {
  _Recording() : super(SSHClientManager());

  List<String>? lastArgs;
  Map<String, String>? lastEnv;
  String? lastRepo;
  ({String path, Uint8List bytes, String? routingRepo})? lastUpload;
  final envCalls = <String>[];
  String? binaryAsked;

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
    lastRepo = repoPath;
    lastArgs = gitArgs;
    lastEnv = extraEnv;
    return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  List<String>? lastStreamArgs;
  Map<String, String>? lastStreamEnv;

  @override
  Future<SSHStreamHandle> executeStream({
    required String repoPath,
    required List<String> gitArgs,
    Map<String, String>? extraEnv,
    Duration openTimeout = SSHCommandExecutor.defaultTimeout,
    OperationDescriptor? operation,
    OperationEventCallback? onOperationEvent,
  }) async {
    lastStreamArgs = gitArgs;
    lastStreamEnv = extraEnv;
    throw StateError('no transport in the harness');
  }

  @override
  Future<void> uploadBytes(
    String remotePath,
    Uint8List bytes, {
    String? routingRepo,
  }) async {
    lastUpload = (path: remotePath, bytes: bytes, routingRepo: routingRepo);
  }

  @override
  void configureEnvironment({
    String? path,
    Map<String, String> binaries = const {},
  }) => envCalls.add('configure');

  @override
  String? resolvedBinaryPath(String name) {
    binaryAsked = name;
    return '/resolved/$name';
  }

  @override
  void setForgeTokenNeutralization(Iterable<String> vars) =>
      envCalls.add('neutralize');

  @override
  void resetEnvironment() => envCalls.add('reset');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ---- the wrapper implementations, driven over a recording inner ---------
  //
  // `SSHCommandExecutor` and `LocalCommandExecutor` are the two that own a
  // transport rather than wrapping one; they cannot be driven by this harness
  // without a live socket or real child processes, and both are already the
  // most-tested implementations (126 and 34 test files). They are EXCLUDED, and
  // this comment is the record of that rather than a silent gap.

  ScopedCommandExecutor scoped(
    _Recording inner, {
    Map<String, String>? scope,
  }) => ScopedCommandExecutor(inner, (_) => scope);

  ActivityCommandExecutor activity(_Recording inner) => ActivityCommandExecutor(
    inner,
    onOperationEvent: (_) {},
    resolveDescriptor:
        ({
          required String repositoryPath,
          required ExecLane lane,
          required List<String> argv,
        }) => null,
  );

  group('R1 — argv reaches the inner executor as a List, unmodified', () {
    test('ScopedCommandExecutor', () async {
      final inner = _Recording();
      await scoped(inner).execute(repoPath: '/r', gitArgs: ['status', '-s']);
      expect(inner.lastArgs, ['status', '-s']);
    });
    test('ActivityCommandExecutor', () async {
      final inner = _Recording();
      await activity(inner).execute(repoPath: '/r', gitArgs: ['status', '-s']);
      expect(inner.lastArgs, ['status', '-s']);
    });
  });

  group('R2 — extraEnv reaches the inner executor', () {
    test(
      'ScopedCommandExecutor merges its scope and keeps the caller\'s',
      () async {
        final inner = _Recording();
        await scoped(
          inner,
          scope: {'GIT_DIR': '/g'},
        ).execute(repoPath: '/r', gitArgs: ['status'], extraEnv: {'A': '1'});
        expect(inner.lastEnv, {'GIT_DIR': '/g', 'A': '1'});
      },
    );
    test('ActivityCommandExecutor passes it through', () async {
      final inner = _Recording();
      await activity(
        inner,
      ).execute(repoPath: '/r', gitArgs: ['status'], extraEnv: {'A': '1'});
      expect(inner.lastEnv, {'A': '1'});
    });
  });

  group('R3 — uploadBytes delegates with routingRepo intact', () {
    final payload = Uint8List.fromList([0x00, 0xff, 0x41]);
    test('ScopedCommandExecutor', () async {
      final inner = _Recording();
      await scoped(inner).uploadBytes('/p', payload, routingRepo: '/r');
      expect(inner.lastUpload?.routingRepo, '/r');
      expect(inner.lastUpload?.bytes, orderedEquals(payload));
    });
    test('ActivityCommandExecutor', () async {
      final inner = _Recording();
      await activity(inner).uploadBytes('/p', payload, routingRepo: '/r');
      expect(inner.lastUpload?.routingRepo, '/r');
      expect(inner.lastUpload?.bytes, orderedEquals(payload));
    });
  });

  group('R4 — the environment contract', () {
    test('ScopedCommandExecutor delegates all four', () {
      final inner = _Recording();
      final e = scoped(inner)
        ..configureEnvironment()
        ..setForgeTokenNeutralization(const ['X'])
        ..resetEnvironment();
      expect(e.resolvedBinaryPath('glab'), '/resolved/glab');
      expect(inner.envCalls, ['configure', 'neutralize', 'reset']);
    });

    test('ActivityCommandExecutor delegates all four', () {
      final inner = _Recording();
      final e = activity(inner)
        ..configureEnvironment()
        ..setForgeTokenNeutralization(const ['X'])
        ..resetEnvironment();
      expect(e.resolvedBinaryPath('glab'), '/resolved/glab');
      expect(inner.envCalls, ['configure', 'neutralize', 'reset']);
    });

    test('ProxyCommandExecutor DELIBERATELY holds no environment', () {
      // Not a violation: a pop-out relays exec to the main isolate, whose real
      // executor owns binary resolution and does the argv[0] rewrite. The
      // no-ops exist so an incidental call cannot throw. Pinned so the
      // *intent* is asserted — if someone later makes these delegate, that is
      // a decision, and this test makes them take it deliberately.
      final p = ProxyCommandExecutor.forWindow('w1')
        ..configureEnvironment()
        ..setForgeTokenNeutralization(const ['X'])
        ..resetEnvironment();
      expect(
        p.resolvedBinaryPath('glab'),
        isNull,
        reason:
            'documented: forge credential helpers fall back to the bare '
            'CLI name in a pop-out',
      );
    });
  });

  group('R5 — streaming is supported or refused, never silently wrong', () {
    test(
      'ScopedCommandExecutor scopes the stream as well as the command',
      () async {
        // The difference that would matter: a scoped repo whose GIT_DIR reaches
        // `execute` but not `executeStream` would arm its watcher against the
        // wrong directory — visible as a repo that never refreshes, not as an
        // error.
        final inner = _Recording();
        await expectLater(
          scoped(
            inner,
            scope: {'GIT_DIR': '/g'},
          ).executeStream(repoPath: '/r', gitArgs: const ['x']),
          throwsStateError, // the harness inner has no transport
        );
        expect(inner.lastStreamEnv, {
          'GIT_DIR': '/g',
        }, reason: 'the scope must reach executeStream, not only execute');
        expect(inner.lastStreamArgs, ['x']);
      },
    );

    test('ProxyCommandExecutor refuses streaming, loudly', () {
      expect(
        () => ProxyCommandExecutor.forWindow(
          'w1',
        ).executeStream(repoPath: '/r', gitArgs: const ['x']),
        throwsUnsupportedError,
        reason: 'a documented refusal, not a silent no-op',
      );
    });
  });

  group('R6 — uploadBytes refuses when it cannot route', () {
    test('ProxyCommandExecutor requires routingRepo', () async {
      await expectLater(
        ProxyCommandExecutor.forWindow(
          'w1',
        ).uploadBytes('/p', Uint8List(0), routingRepo: null),
        throwsA(isA<ProxyExecuteException>()),
      );
    });
  });
}
