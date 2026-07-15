// git cat-file --batch framing parser + one-shot batch helpers.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/exec/command_drain.dart';
import 'package:remote_magic_git/core/git/git_cat_file_batch.dart';

Uint8List _batchBytes(List<List<int>> chunks) {
  final b = BytesBuilder();
  for (final c in chunks) {
    b.add(c);
  }
  return b.takeBytes();
}

Uint8List _present(String oid, String type, List<int> content) {
  final header = utf8.encode('$oid $type ${content.length}\n');
  return _batchBytes([
    header,
    content,
    [0x0a],
  ]);
}

void main() {
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
    final objects = parseCatFileBatch(
      bytes,
      requests: ['rev:a', 'rev:b'],
    );
    expect(objects, hasLength(2));
    expect(objects[0].missing, isFalse);
    expect(objects[0].request, 'rev:a');
    expect(utf8.decode(objects[0].content!), 'hi');
    expect(objects[1].missing, isTrue);
    expect(objects[1].request, 'rev:b');
  });

  test('rejects oversized object', () {
    final header = utf8.encode('c' * 40 + ' blob ${maxCatFileObjectBytes + 1}\n');
    // Content not fully present — size check fires first.
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

  test('catFileBatchScript escapes specs', () {
    final script = catFileBatchScript(['HEAD:a b', 'main:x']);
    expect(script, contains('git cat-file --batch'));
    expect(script, contains("printf '%s\\n'"));
    // Path with space is single-quoted by ShellEscaper.
    expect(script, contains("'HEAD:a b'"));
  });
}
