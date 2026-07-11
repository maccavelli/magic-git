// ProxyCommandExecutor against a mocked method channel: the request map it
// sends, typed rethrow of the failure envelope, out-of-order concurrent
// resolution, the exclusive-lane mutation callback, and bridge-down handling.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/exec/exec_proxy_codec.dart';
import 'package:remote_magic_git/core/exec/proxy_command_executor.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

const _channel = MethodChannel('magicgit/history/hub');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(_channel, null);
  });

  test('sends the encoded request and decodes a success', () async {
    late Map<Object?, Object?> seen;
    messenger.setMockMethodCallHandler(_channel, (call) async {
      expect(call.method, 'execute');
      seen = call.arguments as Map<Object?, Object?>;
      return encodeExecuteResult(
        const SSHCommandResult(exitCode: 0, stdout: 'log-output', stderr: ''),
      );
    });

    final executor = ProxyCommandExecutor();
    final result = await executor.execute(
      repoPath: '/srv/repo',
      gitArgs: ['git', 'log'],
      lane: ExecLane.read,
      compress: true,
      timeout: const Duration(seconds: 30),
    );

    expect(result.stdout, 'log-output');
    expect(seen['repoPath'], '/srv/repo');
    expect(seen['gitArgs'], ['git', 'log']);
    expect(seen['lane'], 'read');
    expect(seen['compress'], true);
    expect(seen['timeoutMs'], 30000);
  });

  test('rethrows each typed executor exception from the envelope', () async {
    var kind = 'timeout';
    messenger.setMockMethodCallHandler(_channel, (call) async {
      return switch (kind) {
        'timeout' => encodeExecuteError(const SSHCommandTimeout('git log')),
        'superseded' => encodeExecuteError(
            const SSHCommandSuperseded('git log')),
        _ => encodeExecuteError(const SSHOutputExceeded('git log')),
      };
    });

    final executor = ProxyCommandExecutor();
    Future<void> run() =>
        executor.execute(repoPath: '/r', gitArgs: ['git', 'log']);

    await expectLater(run, throwsA(isA<SSHCommandTimeout>()));
    kind = 'superseded';
    await expectLater(run, throwsA(isA<SSHCommandSuperseded>()));
    kind = 'outputExceeded';
    await expectLater(run, throwsA(isA<SSHOutputExceeded>()));
  });

  test('a dead bridge surfaces as a readable ProxyExecuteException', () async {
    // No handler installed at all → MissingPluginException; and an explicit
    // PlatformException path too.
    final executor = ProxyCommandExecutor();
    messenger.setMockMethodCallHandler(_channel, (call) async {
      throw PlatformException(code: 'RELAY_DOWN', message: 'window closing');
    });
    await expectLater(
      () => executor.execute(repoPath: '/r', gitArgs: ['git', 'status']),
      throwsA(
        isA<ProxyExecuteException>().having(
          (e) => e.toString(),
          'message',
          contains('window closing'),
        ),
      ),
    );
  });

  test('concurrent calls resolve independently and out of order', () async {
    final gates = <String, Completer<void>>{
      'first': Completer<void>(),
      'second': Completer<void>(),
    };
    messenger.setMockMethodCallHandler(_channel, (call) async {
      final args = call.arguments as Map<Object?, Object?>;
      final tag = (args['gitArgs'] as List).last as String;
      await gates[tag]!.future;
      return encodeExecuteResult(
        SSHCommandResult(exitCode: 0, stdout: tag, stderr: ''),
      );
    });

    final executor = ProxyCommandExecutor();
    final resolved = <String>[];
    final first = executor
        .execute(repoPath: '/r', gitArgs: ['git', 'first'], lane: ExecLane.read)
        .then((r) => resolved.add(r.stdout));
    final second = executor
        .execute(repoPath: '/r', gitArgs: ['git', 'second'], lane: ExecLane.read)
        .then((r) => resolved.add(r.stdout));

    // Release in reverse order — replies must pair with their own calls.
    gates['second']!.complete();
    await second;
    gates['first']!.complete();
    await first;
    expect(resolved, ['second', 'first']);
  });

  test('the mutation callback fires for exclusive-lane results only — even '
      'failed ones — and not for thrown errors', () async {
    var exitCode = 0;
    var fail = false;
    messenger.setMockMethodCallHandler(_channel, (call) async {
      if (fail) return encodeExecuteError(const SSHCommandTimeout('git x'));
      return encodeExecuteResult(
        SSHCommandResult(exitCode: exitCode, stdout: '', stderr: ''),
      );
    });

    final mutated = <String>[];
    final executor = ProxyCommandExecutor(onMutationCompleted: mutated.add);

    await executor.execute(repoPath: '/repo', gitArgs: ['git', 'log'],
        lane: ExecLane.read);
    expect(mutated, isEmpty, reason: 'reads never fire the callback');

    await executor.execute(repoPath: '/repo', gitArgs: ['git', 'commit']);
    expect(mutated, ['/repo']);

    // A conflicted cherry-pick exits non-zero but HAS mutated the repo.
    exitCode = 1;
    await executor.execute(repoPath: '/repo', gitArgs: ['git', 'cherry-pick']);
    expect(mutated, ['/repo', '/repo']);

    fail = true;
    await expectLater(
      () => executor.execute(repoPath: '/repo', gitArgs: ['git', 'reset']),
      throwsA(isA<SSHCommandTimeout>()),
    );
    expect(mutated.length, 2, reason: 'nothing ran — no refresh signal');
  });
}
