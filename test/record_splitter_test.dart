// MADR 0045 phase 1. The stdout record splitter, testable without a stream.
// Its reason to exist is 0024 A1: splitting must be linear in the chunk.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/watch/source/remote/record_splitter.dart';

void main() {
  RecordSplitter newline({void Function()? onOverflow}) => RecordSplitter(
    delimiter: '\n',
    maxBufferChars: 64,
    onOverflow: onOverflow,
  );

  test('complete records are returned in order', () {
    expect(newline().add('a/1\nb/2\nc/3\n'), ['a/1', 'b/2', 'c/3']);
  });

  test('a record split across chunks survives intact', () {
    final splitter = newline();
    expect(splitter.add('src/lo'), isEmpty);
    expect(splitter.add('ng/path.dart\nnext'), ['src/long/path.dart']);
  });

  test('a trailing partial is kept for the next chunk', () {
    final splitter = newline();
    expect(splitter.add('one\ntw'), ['one']);
    expect(splitter.add('o\n'), ['two']);
  });

  test('an undelimited flood past the cap is dropped and reported', () {
    var overflows = 0;
    final splitter = newline(onOverflow: () => overflows++);
    expect(splitter.add('x' * 65), isEmpty);
    expect(overflows, 1);
    expect(splitter.add('fresh\n'), [
      'fresh',
    ], reason: 'the dropped partial must not prefix the next record');
  });

  test('a large burst is linear', () {
    const records = 20000;
    final blob = [
      for (var i = 0; i < records; i++) 'src/m$i/f$i.dart',
    ].join('\n');
    final text = '$blob\n';
    const chunkSize = 32 * 1024;
    final splitter = RecordSplitter(delimiter: '\n', maxBufferChars: 1 << 20);

    final sw = Stopwatch()..start();
    var seen = 0;
    for (var i = 0; i < text.length; i += chunkSize) {
      final end = i + chunkSize < text.length ? i + chunkSize : text.length;
      seen += splitter.add(text.substring(i, end)).length;
    }
    sw.stop();

    expect(seen, records);
    // The same bound remote_watch_service_test.dart holds the service to:
    // re-slicing per record measured ~134 ms, a cursor ~1 ms.
    expect(
      sw.elapsedMilliseconds,
      lessThan(50),
      reason: 'splitting must not copy the remaining buffer per record',
    );
  });
}
