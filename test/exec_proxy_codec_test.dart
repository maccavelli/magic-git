// The execute-proxy wire codec: request/response round trips, typed-exception
// preservation across the envelope, and version-skew degradation. Pure Dart —
// no channel machinery involved, by design.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/exec/exec_proxy_codec.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

void main() {
  group('execute request', () {
    test('round-trips every field', () {
      const request = ExecuteRequest(
        repoPath: '/srv/repo',
        gitArgs: ['git', 'log', '--max-count=200'],
        extraEnv: {'GIT_TRACE': '1'},
        stdin: 'todo contents\n',
        timeout: Duration(minutes: 5),
        retries: 1,
        lane: ExecLane.read,
        compress: true,
      );
      final decoded = decodeExecuteRequest(encodeExecuteRequest(request));
      expect(decoded.repoPath, '/srv/repo');
      expect(decoded.gitArgs, ['git', 'log', '--max-count=200']);
      expect(decoded.extraEnv, {'GIT_TRACE': '1'});
      expect(decoded.stdin, 'todo contents\n');
      expect(decoded.timeout, const Duration(minutes: 5));
      expect(decoded.retries, 1);
      expect(decoded.lane, ExecLane.read);
      expect(decoded.compress, isTrue);
    });

    test('null optionals survive', () {
      const request = ExecuteRequest(
        repoPath: '/r',
        gitArgs: ['git', 'status'],
        timeout: Duration(seconds: 60),
        retries: 0,
        lane: ExecLane.exclusive,
        compress: false,
      );
      final decoded = decodeExecuteRequest(encodeExecuteRequest(request));
      expect(decoded.extraEnv, isNull);
      expect(decoded.stdin, isNull);
    });

    test('an unknown lane name degrades to exclusive (the safe default)', () {
      final map = encodeExecuteRequest(
        const ExecuteRequest(
          repoPath: '/r',
          gitArgs: ['git', 'status'],
          timeout: Duration(seconds: 1),
          retries: 0,
          lane: ExecLane.read,
          compress: false,
        ),
      );
      map['lane'] = 'hyperspace'; // a lane from a future version
      expect(decodeExecuteRequest(map).lane, ExecLane.exclusive);
    });
  });

  group('execute response', () {
    test('a success round-trips as an SSHCommandResult', () {
      const result = SSHCommandResult(
        exitCode: 3,
        stdout: 'out\n',
        stderr: 'err\n',
      );
      final decoded = decodeExecuteResponse(encodeExecuteResult(result));
      expect(decoded.exitCode, 3);
      expect(decoded.stdout, 'out\n');
      expect(decoded.stderr, 'err\n');
      expect(decoded.isSuccess, isFalse);
    });

    test('each typed executor exception survives with its command', () {
      expect(
        () => decodeExecuteResponse(
          encodeExecuteError(const SSHCommandTimeout('git log')),
        ),
        throwsA(
          isA<SSHCommandTimeout>().having((e) => e.command, 'command', 'git log'),
        ),
      );
      expect(
        () => decodeExecuteResponse(
          encodeExecuteError(const SSHCommandSuperseded('git fetch')),
        ),
        throwsA(
          isA<SSHCommandSuperseded>().having(
            (e) => e.command,
            'command',
            'git fetch',
          ),
        ),
      );
      expect(
        () => decodeExecuteResponse(
          encodeExecuteError(const SSHOutputExceeded('git diff')),
        ),
        throwsA(
          isA<SSHOutputExceeded>().having(
            (e) => e.command,
            'command',
            'git diff',
          ),
        ),
      );
    });

    test('any other error degrades to ProxyExecuteException with the message',
        () {
      expect(
        () => decodeExecuteResponse(
          encodeExecuteError(StateError('the executor caught fire')),
        ),
        throwsA(
          isA<ProxyExecuteException>().having(
            (e) => e.toString(),
            'message',
            contains('the executor caught fire'),
          ),
        ),
      );
    });
  });

  test('connection event payload round-trips, including nulls', () {
    const event = ConnectionEventPayload(
      phase: 'connected',
      backend: 'ssh',
      repoPath: '/srv/repo',
      connectionLabel: 'Prod',
      host: 'bastion',
    );
    final decoded = ConnectionEventPayload.decode(event.encode());
    expect(decoded.phase, 'connected');
    expect(decoded.backend, 'ssh');
    expect(decoded.repoPath, '/srv/repo');
    expect(decoded.connectionLabel, 'Prod');
    expect(decoded.host, 'bastion');

    const bare = ConnectionEventPayload(phase: 'disconnected', backend: 'local');
    final bareDecoded = ConnectionEventPayload.decode(bare.encode());
    expect(bareDecoded.repoPath, isNull);
    expect(bareDecoded.host, isNull);
  });
}
