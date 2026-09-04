// The execute-proxy wire codec: request/response round trips, typed-exception
// preservation across the envelope, and version-skew degradation. Pure Dart —
// no channel machinery involved, by design.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/exec/exec_proxy_codec.dart';
import 'package:remote_magic_git/core/exec/operation_activity.dart';
import 'package:remote_magic_git/core/ssh/shell_escaper.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

/// The ObjC StandardMethodCodec the window relay hops through truncates a
/// String at its first NUL; typed data is length-prefixed and immune.
/// Applying this to an encoded payload reproduces what the native hop does to
/// it, so any field carrying command text as a String fails the round-trip —
/// including a field nobody remembered to write a test for.
Object? throughNulLossyCodec(Object? value) => switch (value) {
  // Typed data first: Uint8List is also a List<Object?>, so the list arm
  // below would rebuild it as a plain list and strip the very typing that
  // makes it immune.
  final Uint8List bytes => bytes,
  final String text => text.split('\u0000').first,
  final Map<Object?, Object?> map => {
    for (final entry in map.entries)
      entry.key: throughNulLossyCodec(entry.value),
  },
  final List<Object?> list => [
    for (final element in list) throughNulLossyCodec(element),
  ],
  _ => value,
};

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
        operation: OperationDescriptor(
          id: OperationId('op-1'),
          repositoryPath: '/srv/repo',
          label: 'Refresh repository',
          kind: OperationKind.synchronization,
          lane: ExecLane.sync,
        ),
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
      expect(decoded.activityIdle, isNull);
      expect(decoded.operation?.id, const OperationId('op-1'));
      expect(decoded.operation?.label, 'Refresh repository');
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
      expect(decoded.operation, isNull);
      expect(decoded.activityIdle, isNull);
    });

    test('activityIdleMs round-trips and omitted means wall clock', () {
      const request = ExecuteRequest(
        repoPath: '/r',
        gitArgs: ['git', 'fetch'],
        timeout: Duration(minutes: 30),
        retries: 0,
        lane: ExecLane.sync,
        compress: false,
        activityIdle: Duration(minutes: 3),
      );
      final decoded = decodeExecuteRequest(encodeExecuteRequest(request));
      expect(decoded.activityIdle, const Duration(minutes: 3));
      final omitted = decodeExecuteRequest(
        encodeExecuteRequest(
          const ExecuteRequest(
            repoPath: '/r',
            gitArgs: ['git', 'status'],
            timeout: Duration(seconds: 60),
            retries: 0,
            lane: ExecLane.read,
            compress: false,
          ),
        ),
      );
      expect(omitted.activityIdle, isNull);
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
        operationId: OperationId('op-1'),
      );
      final decoded = decodeExecuteResponse(encodeExecuteResult(result));
      expect(decoded.exitCode, 3);
      expect(decoded.stdout, 'out\n');
      expect(decoded.stderr, 'err\n');
      expect(decoded.isSuccess, isFalse);
      expect(decoded.operationId, const OperationId('op-1'));
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

    test('NUL-bearing stderr travels as bytes on the wire', () {
      // Sibling of the stdout case: a git failure message can carry
      // NUL-delimited paths (`clean -n -z`, `check-ignore -z`), so stderr is
      // exposed to exactly the same truncation.
      const result = SSHCommandResult(
        exitCode: 128,
        stdout: '',
        stderr: 'fatal: pathspec\u0000lib/a.dart\u0000did not match',
      );
      final wire = encodeExecuteResult(result);
      expect(wire['stderr'], isA<Uint8List>());
      expect(
        decodeExecuteResponse(wire).stderr,
        'fatal: pathspec\u0000lib/a.dart\u0000did not match',
      );
    });

    test('each typed executor exception survives with its command', () {
      expect(
        () => decodeExecuteResponse(
          encodeExecuteError(const SSHCommandTimeout('git log')),
        ),
        throwsA(
          isA<SSHCommandTimeout>().having(
            (e) => e.command,
            'command',
            'git log',
          ),
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
      // The type is the whole point for this one: `isTransportNotReady` is an
      // exact `is` test, and the panes spin rather than error on it (MADR
      // 0018). Degrading it to ProxyExecuteException across the relay put the
      // raw developer string into every pop-out's Repository pane.
      expect(
        () => decodeExecuteResponse(
          encodeExecuteError(const SSHTransportNotReady('git status')),
        ),
        throwsA(
          isA<SSHTransportNotReady>().having(
            (e) => e.command,
            'command',
            'git status',
          ),
        ),
      );
    });

    test(
      'a not-ready envelope also carries text for a version-skewed peer',
      () {
        // An OLD decoder has no 'transportNotReady' case and falls to its
        // `default:` arm, which reads 'message'. Without it that peer would
        // surface "unknown proxy error" — strictly worse than the pre-fix text.
        final envelope = encodeExecuteError(
          const SSHTransportNotReady('git status'),
        );
        expect(envelope['message'], contains('git status'));
      },
    );

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
      expect(
        () => decodeUploadBytesResponse(encodeUploadBytesResult()),
        returnsNormally,
      );
    });

    test('uploadBytes error envelope rethrows typed failures', () {
      expect(
        () => decodeUploadBytesResponse(
          encodeUploadBytesError(const SSHCommandTimeout('upload')),
        ),
        throwsA(isA<SSHCommandTimeout>()),
      );
    });

    test(
      'any other error degrades to ProxyExecuteException with the message',
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
      },
    );
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

    const bare = ConnectionEventPayload(
      phase: 'disconnected',
      backend: 'local',
    );
    final bareDecoded = ConnectionEventPayload.decode(bare.encode());
    expect(bareDecoded.repoPath, isNull);
    expect(bareDecoded.host, isNull);
  });

  group('NUL-lossy transport', () {
    test('an execute request survives the native codec', () {
      // The structural guard: any field carrying command text as a String is
      // beheaded here, and only typed data comes through whole.
      const request = ExecuteRequest(
        repoPath: '/srv/repo',
        gitArgs: ['git', 'check-ignore', '-z', '--stdin'],
        stdin: 'build\u0000lib/a.dart\u0000.dart_tool',
        timeout: Duration(seconds: 30),
        retries: 0,
        lane: ExecLane.read,
        compress: false,
      );

      final hopped =
          throughNulLossyCodec(encodeExecuteRequest(request))
              as Map<Object?, Object?>;
      final survived = decodeExecuteRequest(hopped.cast<String, Object?>());

      expect(survived.stdin, request.stdin);
      expect(survived.gitArgs, request.gitArgs);
      expect(survived.repoPath, request.repoPath);
      expect(survived.lane, request.lane);
    });

    test('an execute response survives the native codec', () {
      const result = SSHCommandResult(
        exitCode: 0,
        stdout: '# branch.oid abc\u0000?? a.txt\u0000RMGSNAP0',
        stderr: 'warning:\u0000path skipped',
      );

      final hopped =
          throughNulLossyCodec(encodeExecuteResult(result))
              as Map<Object?, Object?>;
      final survived = decodeExecuteResponse(hopped.cast<String, Object?>());

      expect(survived.stdout, result.stdout);
      expect(survived.stderr, result.stderr);
      expect(survived.exitCode, 0);
    });

    test('argv stays strings by contract', () {
      // The codec deliberately leaves argv/env as strings: a NUL cannot reach
      // them, because ShellEscaper refuses one long before the wire. Pinned so
      // the structural guard above is never "fixed" by turning every field
      // into bytes.
      final wire = encodeExecuteRequest(
        const ExecuteRequest(
          repoPath: '/srv/repo',
          gitArgs: ['git', 'status'],
          timeout: Duration(seconds: 5),
          retries: 0,
          lane: ExecLane.read,
          compress: false,
        ),
      );
      expect(wire['gitArgs'], isA<List<String>>());
      expect(
        () => ShellEscaper.escape('a\u0000b'),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
