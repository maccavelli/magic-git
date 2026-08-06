// The execute-proxy wire codec: request/response round trips, typed-exception
// preservation across the envelope, and version-skew degradation. Pure Dart —
// no channel machinery involved, by design.

import 'dart:typed_data';

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

    test('NUL-delimited stdin survives, and travels as bytes on the wire', () {
      // `check-ignore -z --stdin` joins paths with NUL. A string payload
      // would be beheaded at the first NUL by the native codec the window
      // relay hops through — the wire shape MUST be typed data.
      const request = ExecuteRequest(
        repoPath: '/r',
        gitArgs: ['git', 'check-ignore', '-z', '--stdin'],
        stdin: 'build\u0000lib/a.dart\u0000.dart_tool',
        timeout: Duration(seconds: 30),
        retries: 0,
        lane: ExecLane.read,
        compress: false,
      );
      final wire = encodeExecuteRequest(request);
      expect(wire['stdin'], isA<Uint8List>());
      expect(
        decodeExecuteRequest(wire).stdin,
        'build\u0000lib/a.dart\u0000.dart_tool',
      );
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

    test('NUL-bearing stdout survives, and travels as bytes on the wire', () {
      // The combined status/refs snapshot opens with `status --porcelain=v2
      // -z` — NUL-delimited — so its stdout ALWAYS embeds NULs. As a string
      // this was truncated at the first NUL by the native codec on the
      // window relay, beheading the snapshot before its first section
      // separator: the History pop-out never got refs. Bytes are immune.
      const result = SSHCommandResult(
        exitCode: 0,
        stdout: '# branch.oid abc\u0000?? a.txt\u0000RMGSNAP0',
        stderr: '',
      );
      final wire = encodeExecuteResult(result);
      expect(wire['stdout'], isA<Uint8List>());
      expect(
        decodeExecuteResponse(wire).stdout,
        '# branch.oid abc\u0000?? a.txt\u0000RMGSNAP0',
      );
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

    test('uploadBytes request round-trips path, bytes, and routingRepo', () {
      final bytes = Uint8List.fromList([0, 1, 2, 255, 0]);
      final request = UploadBytesRequest(
        remotePath: '/srv/repo/lib/a.dart',
        bytes: bytes,
        routingRepo: '/srv/repo',
      );
      final wire = encodeUploadBytesRequest(request);
      expect(wire['bytes'], isA<Uint8List>());
      final decoded = decodeUploadBytesRequest(wire);
      expect(decoded.remotePath, '/srv/repo/lib/a.dart');
      expect(decoded.routingRepo, '/srv/repo');
      expect(decoded.bytes, bytes);
    });

    test('uploadBytes success envelope decodes without throw', () {
      expect(() => decodeUploadBytesResponse(encodeUploadBytesResult()), returnsNormally);
    });

    test('uploadBytes error envelope rethrows typed failures', () {
      expect(
        () => decodeUploadBytesResponse(
          encodeUploadBytesError(const SSHCommandTimeout('upload')),
        ),
        throwsA(isA<SSHCommandTimeout>()),
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
