// git cat-file --batch framing parser + one-shot batch helpers + session.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/exec/command_drain.dart';
import 'package:remote_magic_git/core/git/git_cat_file_batch.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
// Hide drain re-exports so SSHOutputExceeded is unambiguous with command_drain.
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart'
    hide
        SSHOutputExceeded,
        OutputByteBudget,
        collectBounded,
        boundedBytes,
        maxCommandOutputChars,
        maxCommandOutputBytes;

Uint8List _batchBytes(List<List<int>> chunks) {
  final b = BytesBuilder();
  for (final c in chunks) {
    b.add(c);
  }
  return b.takeBytes();
}

/// The stdout the arming script actually produces: base64 of the raw batch.
///
/// The old fixtures handed the service `utf8.decode(rawBytes)`, which could
/// only ever hold clean UTF-8 — so the harness itself could not express a
/// binary blob, and the desync bug it caused was invisible to every test here
/// (0022 M10). `utf8.decode` without allowMalformed would in fact THROW on
/// such a payload.
String _wireStdout(List<int> rawBatch) => base64.encode(rawBatch);

Uint8List _present(String oid, String type, List<int> content) {
  final header = utf8.encode('$oid $type ${content.length}\n');
  return _batchBytes([
    header,
    content,
    [0x0a],
  ]);
}

/// Minimal [CommandExecutor] that records calls and returns scripted results.
class _RecordingExecutor implements CommandExecutor {
  final List<List<String>> calls = [];
  final List<bool> compressFlags = [];
  SSHCommandResult Function(List<String> gitArgs)? handler;
  Completer<void>? hold;
  int inFlight = 0;
  int peakInFlight = 0;

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
    calls.add(List<String>.from(gitArgs));
    compressFlags.add(compress);
    inFlight++;
    if (inFlight > peakInFlight) peakInFlight = inFlight;
    final gate = hold;
    if (gate != null) await gate.future;
    inFlight--;
    return handler?.call(gitArgs) ??
        const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  @override
  Future<SSHStreamHandle> executeStream({
    required String repoPath,
    required List<String> gitArgs,
    Map<String, String>? extraEnv,
    Duration openTimeout = SSHCommandExecutor.defaultTimeout,
    OperationDescriptor? operation,
    OperationEventCallback? onOperationEvent,
  }) => throw UnimplementedError();

  @override
  Future<void> uploadBytes(
    String remotePath,
    Uint8List bytes, {
    String? routingRepo,
  }) async {}

  @override
  void configureEnvironment({
    String? path,
    Map<String, String> binaries = const {},
  }) {}

  @override
  String? resolvedBinaryPath(String name) => null;

  @override
  void setForgeTokenNeutralization(Iterable<String> vars) {}

  @override
  void resetEnvironment() {}
}

void main() {
  group('parseCatFileBatch', () {
    test('parses present object with binary-safe content', () {
      final body = <int>[0x00, 0x01, 0xff, 0x0a, 0x41]; // includes NUL and LF
      final oid = 'a' * 40;
      final bytes = _present(oid, 'blob', body);
      final objects = parseCatFileBatch(bytes, requests: ['HEAD:file']);
      expect(objects, hasLength(1));
      expect(objects.single.missing, isFalse);
      expect(objects.single.oid, oid);
      expect(objects.single.type, 'blob');
      expect(objects.single.size, body.length);
      expect(objects.single.content, body);
      expect(objects.single.request, 'HEAD:file');
    });

    test('parses missing object', () {
      final bytes = Uint8List.fromList(utf8.encode('deadbeef missing\n'));
      final objects = parseCatFileBatch(bytes);
      expect(objects, hasLength(1));
      expect(objects.single.missing, isTrue);
      expect(objects.single.request, 'deadbeef');
      expect(objects.single.content, isNull);
    });

    test('parses mixed present and missing', () {
      final oid = 'b' * 40;
      final present = _present(oid, 'blob', utf8.encode('hi'));
      final missing = utf8.encode('nope missing\n');
      final bytes = _batchBytes([present, missing]);
      final objects = parseCatFileBatch(bytes, requests: ['rev:a', 'rev:b']);
      expect(objects, hasLength(2));
      expect(objects[0].missing, isFalse);
      expect(objects[0].request, 'rev:a');
      expect(utf8.decode(objects[0].content!), 'hi');
      expect(objects[1].missing, isTrue);
      expect(objects[1].request, 'rev:b');
    });

    test('parses multiple present objects', () {
      final a = _present('a' * 40, 'blob', utf8.encode('one'));
      final b = _present('b' * 40, 'blob', utf8.encode('two'));
      final objects = parseCatFileBatch(
        _batchBytes([a, b]),
        requests: ['r:a', 'r:b'],
      );
      expect(objects, hasLength(2));
      expect(utf8.decode(objects[0].content!), 'one');
      expect(utf8.decode(objects[1].content!), 'two');
    });

    test('empty input yields empty list', () {
      expect(parseCatFileBatch(Uint8List(0)), isEmpty);
    });

    test('rejects oversized object', () {
      final header = utf8.encode(
        'c' * 40 + ' blob ${maxCatFileObjectBytes + 1}\n',
      );
      expect(
        () => parseCatFileBatch(header),
        throwsA(isA<SSHOutputExceeded>()),
      );
    });

    test('rejects truncated content', () {
      final header = utf8.encode('${'d' * 40} blob 10\n');
      final short = Uint8List.fromList([...header, 1, 2, 3]);
      expect(() => parseCatFileBatch(short), throwsA(isA<FormatException>()));
    });

    test('rejects missing trailing LF after content', () {
      final oid = 'e' * 40;
      final header = utf8.encode('$oid blob 3\n');
      // content "abc" but no trailing LF
      final bytes = Uint8List.fromList([...header, 0x61, 0x62, 0x63]);
      expect(() => parseCatFileBatch(bytes), throwsA(isA<FormatException>()));
    });

    test('rejects malformed header (too few fields)', () {
      final bytes = Uint8List.fromList(utf8.encode('onlytwo fields\n'));
      expect(() => parseCatFileBatch(bytes), throwsA(isA<FormatException>()));
    });

    test('rejects unterminated header', () {
      final bytes = Uint8List.fromList(utf8.encode('no newline here'));
      expect(() => parseCatFileBatch(bytes), throwsA(isA<FormatException>()));
    });

    test('rejects non-numeric size', () {
      final bytes = Uint8List.fromList(utf8.encode('${'f' * 40} blob xyz\n'));
      expect(() => parseCatFileBatch(bytes), throwsA(isA<FormatException>()));
    });
  });

  group('catFileBatchScript', () {
    test('escapes specs', () {
      final script = catFileBatchScript(['HEAD:a b', 'main:x']);
      expect(script, contains('git cat-file --batch'));
      expect(script, contains("printf '%s\\n'"));
      expect(script, contains("'HEAD:a b'"));
    });

    test('rejects empty specs', () {
      expect(() => catFileBatchScript([]), throwsArgumentError);
    });
  });

  group('GitCatFileBatch.showBlobsBatch', () {
    test('empty keys returns empty map without execute', () async {
      final exec = _RecordingExecutor();
      final batch = GitCatFileBatch(exec);
      final result = await batch.showBlobsBatch('/repo', []);
      expect(result, isEmpty);
      expect(exec.calls, isEmpty);
    });

    test(
      'single key with showOne short-circuits without remote batch',
      () async {
        final exec = _RecordingExecutor();
        final batch = GitCatFileBatch(exec);
        const key = (rev: 'HEAD', path: 'a.txt');
        final result = await batch.showBlobsBatch(
          '/repo',
          [key],
          showOne: (repo, rev, path) async {
            expect(repo, '/repo');
            expect(rev, 'HEAD');
            expect(path, 'a.txt');
            return 'solo';
          },
        );
        expect(exec.calls, isEmpty);
        expect(utf8.decode(result[key]!), 'solo');
      },
    );

    test('multi-key success parses batch stdout in one execute', () async {
      final oid1 = '1' * 40;
      final oid2 = '2' * 40;
      final stdout = _wireStdout(
        _batchBytes([
          _present(oid1, 'blob', utf8.encode('alpha')),
          _present(oid2, 'blob', utf8.encode('beta')),
        ]),
      );
      final exec = _RecordingExecutor()
        ..handler = (_) =>
            SSHCommandResult(exitCode: 0, stdout: stdout, stderr: '');
      final batch = GitCatFileBatch(exec);
      const k1 = (rev: 'HEAD', path: 'a');
      const k2 = (rev: 'HEAD', path: 'b');
      final result = await batch.showBlobsBatch('/repo', [k1, k2]);
      expect(exec.calls, hasLength(1));
      expect(exec.compressFlags.single, isTrue);
      expect(exec.calls.single[0], 'sh');
      expect(exec.calls.single[2], contains('git cat-file --batch'));
      expect(utf8.decode(result[k1]!), 'alpha');
      expect(utf8.decode(result[k2]!), 'beta');
    });

    test('non-zero exit falls back to showOne', () async {
      final exec = _RecordingExecutor()
        ..handler = (_) =>
            const SSHCommandResult(exitCode: 128, stdout: '', stderr: 'fatal');
      final batch = GitCatFileBatch(exec);
      const k1 = (rev: 'HEAD', path: 'a');
      const k2 = (rev: 'main', path: 'b');
      final result = await batch.showBlobsBatch('/repo', [
        k1,
        k2,
      ], showOne: (repo, rev, path) async => '$rev:$path-content');
      expect(utf8.decode(result[k1]!), 'HEAD:a-content');
      expect(utf8.decode(result[k2]!), 'main:b-content');
    });

    test('missing objects omitted unless requireAll', () async {
      final oid = '9' * 40;
      final stdout = _wireStdout(
        _batchBytes([
          _present(oid, 'blob', utf8.encode('ok')),
          utf8.encode('HEAD:missing missing\n'),
        ]),
      );
      final exec = _RecordingExecutor()
        ..handler = (_) =>
            SSHCommandResult(exitCode: 0, stdout: stdout, stderr: '');
      final batch = GitCatFileBatch(exec);
      const k1 = (rev: 'HEAD', path: 'ok');
      const k2 = (rev: 'HEAD', path: 'missing');
      final soft = await batch.showBlobsBatch('/repo', [k1, k2]);
      expect(soft.keys, [k1]);

      await expectLater(
        batch.showBlobsBatch('/repo', [k1, k2], requireAll: true),
        throwsA(isA<StateError>()),
      );
    });

    test('batch failure without showOne rethrows', () async {
      final exec = _RecordingExecutor()
        ..handler = (_) =>
            const SSHCommandResult(exitCode: 1, stdout: '', stderr: 'boom');
      final batch = GitCatFileBatch(exec);
      await expectLater(
        batch.showBlobsBatch('/repo', [(rev: 'HEAD', path: 'a')]),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('GitService.showBlobsBatch', () {
    test('decodes batch bytes to strings for multi-key fetch', () async {
      final oid1 = '1' * 40;
      final oid2 = '2' * 40;
      final stdout = _wireStdout(
        _batchBytes([
          _present(oid1, 'blob', utf8.encode('hello')),
          _present(oid2, 'blob', utf8.encode('world')),
        ]),
      );
      final exec = _RecordingExecutor()
        ..handler = (_) =>
            SSHCommandResult(exitCode: 0, stdout: stdout, stderr: '');
      final git = GitService(exec);
      final map = await git.showBlobsBatch('/repo', [
        (rev: 'HEAD', path: 'a'),
        (rev: 'HEAD', path: 'b'),
      ]);
      expect(map[(rev: 'HEAD', path: 'a')], 'hello');
      expect(map[(rev: 'HEAD', path: 'b')], 'world');
    });

    test('empty keys short-circuit', () async {
      final exec = _RecordingExecutor();
      final git = GitService(exec);
      expect(await git.showBlobsBatch('/repo', []), isEmpty);
      expect(exec.calls, isEmpty);
    });
  });

  test('a binary blob does not corrupt the objects after it', () async {
    // 0022 M10. The service used to re-encode stdout that had already been
    // UTF-8 decoded with allowMalformed, which is not length-preserving: a
    // 0xFF became a 3-byte U+FFFD. Since the parser frames each object by
    // git's own byte COUNT, that shifted every following object — and the
    // non-requireAll path then returned the WRONG CONTENT FOR THE WRONG KEY
    // silently, rather than failing.
    final binary = [0x50, 0x4e, 0x47, 0xff, 0xfe, 0x00, 0xff];
    final stdout = _wireStdout(
      _batchBytes([
        _present('1' * 40, 'blob', binary),
        _present('2' * 40, 'blob', utf8.encode('after-the-binary')),
      ]),
    );
    final exec = _RecordingExecutor()
      ..handler = (_) =>
          SSHCommandResult(exitCode: 0, stdout: stdout, stderr: '');
    final batch = GitCatFileBatch(exec);
    const k1 = (rev: 'HEAD', path: 'bin.dat');
    const k2 = (rev: 'HEAD', path: 'after.txt');

    final result = await batch.showBlobsBatch('/repo', [k1, k2]);

    expect(result[k1], binary, reason: 'binary bytes must survive verbatim');
    expect(
      utf8.decode(result[k2]!),
      'after-the-binary',
      reason: 'the object AFTER a binary one is what used to be corrupted',
    );
  });

  test('the batch script keeps git\'s exit status, not base64\'s', () {
    // A pipeline reports its last command's status, so piping cat-file
    // straight into base64 would turn a failed read into exit 0 with empty
    // output — a silent "no such object".
    final script = catFileBatchScript(const ['HEAD:a']);
    expect(script, contains('mktemp'));
    expect(script, contains('exit 65'));
    expect(script, contains('base64'));
  });
}
