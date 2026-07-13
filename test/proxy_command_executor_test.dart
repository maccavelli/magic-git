// ProxyCommandExecutor against a mocked method channel: the request map it
// sends, typed rethrow of the failure envelope, out-of-order concurrent
// resolution, the exclusive-lane mutation callback, and bridge-down handling.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/exec/exec_proxy_codec.dart';
import 'package:remote_magic_git/core/exec/proxy_command_executor.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/window/window_channels.dart';

// A concrete per-window hub — the proxy derives this exact name from the id.
const _windowId = '7';
final _channel = MethodChannel(windowHubChannel(_windowId));

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

    final executor = ProxyCommandExecutor.forWindow(_windowId);
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

    final executor = ProxyCommandExecutor.forWindow(_windowId);
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
    final executor = ProxyCommandExecutor.forWindow(_windowId);
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

    final executor = ProxyCommandExecutor.forWindow(_windowId);
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
    final executor = ProxyCommandExecutor.forWindow(_windowId, onMutationCompleted: mutated.add);

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

  group('when the main window stops answering', () {
    // A platform message carries its own reply handle, so if the far side stops
    // answering — the window's hub handler torn down between send and reply, the
    // native relay dropping the message while a window closes — there is nothing
    // to fail. The future simply never completes. The provider waiting on it
    // never leaves AsyncLoading and the pane spins forever, with no error
    // anywhere and nothing in any log.
    //
    // The guard is deliberately NOT a timeout on the command: a proxied command
    // can legitimately take unbounded wall-clock time (the main isolate runs it
    // through its lane scheduler, so a diff can sit queued behind a five-minute
    // commit before it even starts), and a clock long enough never to kill that
    // is far too long to be any use as a liveness signal. So the proxy asks the
    // other question — "is anyone still there?" — which is quick to answer
    // whatever the command is doing.

    ProxyCommandExecutor fastProbe() => ProxyCommandExecutor(
      channel: _channel,
      probeInterval: const Duration(milliseconds: 20),
      probeTimeout: const Duration(milliseconds: 40),
      deadProbes: 2,
    );

    test('a command that is never answered fails instead of hanging', () async {
      // The hub takes the call and is never heard from again — neither the
      // command nor the pings come back.
      messenger.setMockMethodCallHandler(
        _channel,
        (call) => Completer<Map<Object?, Object?>>().future,
      );

      final call = fastProbe().execute(
        repoPath: '/srv/repo',
        gitArgs: ['git', 'diff'],
        lane: ExecLane.read,
      );

      await expectLater(
        call.timeout(
          const Duration(seconds: 5),
          onTimeout: () => fail('the proxy hung — this is the spinning pane'),
        ),
        throwsA(isA<ProxyExecuteException>()),
      );
    });

    test('a slow command is NOT abandoned while the window keeps answering',
        () async {
      // The whole point of probing rather than timing out. This command takes far
      // longer than several probe intervals — as a real one queued behind a
      // commit would — and must be left alone, because the pings are coming back.
      var pings = 0;
      final done = Completer<Map<Object?, Object?>>();
      messenger.setMockMethodCallHandler(_channel, (call) async {
        if (call.method == 'ping') {
          pings++;
          return null;
        }
        return done.future;
      });

      final executor = fastProbe();
      final call = executor.execute(
        repoPath: '/srv/repo',
        gitArgs: ['git', 'diff'],
        lane: ExecLane.read,
      );

      // Long enough that a dead window would have been declared dead several
      // times over.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(pings, greaterThan(2), reason: 'sanity: it really is probing');

      done.complete(
        encodeExecuteResult(
          const SSHCommandResult(exitCode: 0, stdout: 'ok', stderr: ''),
        ),
      );
      final result = await call.timeout(const Duration(seconds: 5));
      expect(
        result.stdout,
        'ok',
        reason: 'a live window running a long command must be waited for, '
            'however long it takes',
      );
    });

    test('a hub whose handler is gone fails readably, not as a raw error',
        () async {
      // No handler at all on the channel: the messenger answers with
      // MissingPluginException, which is NOT a PlatformException and so used to
      // escape the proxy's catch as an unreadable raw error.
      messenger.setMockMethodCallHandler(_channel, null);

      await expectLater(
        fastProbe().execute(
          repoPath: '/srv/repo',
          gitArgs: ['git', 'diff'],
          lane: ExecLane.read,
        ),
        throwsA(isA<ProxyExecuteException>()),
      );
    });

    test('every call waiting on a dead window is abandoned, not just one',
        () async {
      messenger.setMockMethodCallHandler(
        _channel,
        (call) => Completer<Map<Object?, Object?>>().future,
      );

      final executor = fastProbe();
      final calls = [
        for (var i = 0; i < 3; i++)
          executor.execute(
            repoPath: '/srv/repo',
            gitArgs: ['git', 'diff', '$i'],
            lane: ExecLane.read,
          ),
      ];

      for (final call in calls) {
        await expectLater(
          call.timeout(const Duration(seconds: 5)),
          throwsA(isA<ProxyExecuteException>()),
        );
      }
    });
  });
}
