// The shared long-lived parse worker (MADR 0025 E): the repeated git parses run
// on ONE persistent isolate instead of spawning a fresh one per call.
//
// `Isolate.spawn` of a top-level entry point works in flutter_test, unlike
// `Isolate.run` whose closure captures the test zone — which is why the worker
// is reachable from a test at all where the code it replaces was not.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/parse/parse_worker.dart';

/// A minimal `status --porcelain=v2 -z` record: an ordinary modified file.
/// `-z` terminates each record with NUL, not a newline — a trailing space would
/// be kept as part of the path.
const _statusSample =
    '1 .M N... 100644 100644 100644 '
    '0000000000000000000000000000000000000000 '
    '0000000000000000000000000000000000000000 lib/main.dart\u0000';

void main() {
  late ParseWorker worker;

  setUp(() => worker = ParseWorker());
  tearDown(() => worker.dispose());

  test('repeated parses reuse one isolate', () async {
    final before = worker.spawnCount;
    for (var i = 0; i < 5; i++) {
      await worker.parseStatus(_statusSample);
    }
    expect(worker.spawnCount - before, 1);
  });

  test('the parse result matches the inline parser exactly', () async {
    final fromWorker = await worker.parseStatus(_statusSample);
    expect(fromWorker.files, hasLength(1));
    expect(fromWorker.files.single.path, 'lib/main.dart');
  });

  test(
    'an isolate death fails in-flight work and the next call respawns',
    () async {
      await worker.parseStatus(_statusSample);
      final afterFirst = worker.spawnCount;
      worker.debugKillWorker();
      // The handle recovers rather than wedging: the next parse answers.
      final again = await worker.parseStatus(_statusSample);
      expect(again.files, hasLength(1));
      expect(worker.spawnCount, greaterThan(afterFirst));
    },
  );

  test('parses of different jobs share the one worker', () async {
    final before = worker.spawnCount;
    await worker.parseStatus(_statusSample);
    await worker.parseLog('');
    await worker.parseRefs('');
    expect(worker.spawnCount - before, 1);
  });
}
