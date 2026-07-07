// End-to-end for the viewer's Latin-1 / Windows-1252 fallback: a single-byte
// legacy file (no BOM, no NUL) whose high bytes fail the UTF-8 decode is
// re-read as bytes and decoded as Windows-1252, so it renders as text instead
// of binary/mojibake. A fake GitService supplies the same bytes on both the
// UTF-8 (`readFile`) and base64 (`readFileBase64`) paths, exactly as the two
// real reads would over either transport.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/features/viewer/file_content.dart';
import 'package:remote_magic_git/features/viewer/viewer_providers.dart';

const _repo = '/repo';
const _path = 'notes.txt';

// Serves [bytes] as both a UTF-8-with-replacement read (what `cat` decoded as
// UTF-8 yields) and a base64 read (the raw bytes), matching GitService's two
// real read paths.
class _BytesGit extends GitService {
  _BytesGit(this.bytes) : super(SSHCommandExecutor(SSHClientManager()));
  final Uint8List bytes;

  @override
  Future<String> readFile(String repoPath, String path) async =>
      const Utf8Decoder(allowMalformed: true).convert(bytes);

  @override
  Future<String> readFileBase64(String repoPath, String path) async =>
      base64.encode(bytes);
}

Future<FileContent> _classifyBytes(List<int> raw) async {
  final container = ProviderContainer(
    overrides: [
      gitServiceProvider.overrideWithValue(_BytesGit(Uint8List.fromList(raw))),
    ],
  );
  addTearDown(container.dispose);
  // Keep the autoDispose provider alive across the async read rather than
  // reading `.future` on a bare container (which can race disposal).
  final sub = container.listen(
    fileContentProvider((_repo, _path)),
    (_, _) {},
  );
  addTearDown(sub.close);
  return container.read(fileContentProvider((_repo, _path)).future);
}

void main() {
  test('a dense Latin-1 file (classified binary) recovers as text', () async {
    // Many accented bytes → the UTF-8 read is replacement-saturated → binary.
    // "é" (0xE9) repeated with newlines.
    final raw = <int>[];
    for (var i = 0; i < 40; i++) {
      raw.addAll([0x63, 0x61, 0x66, 0xE9, 0x0A]); // "café\n"
    }
    final content = await _classifyBytes(raw);
    expect(content.kind, FileContentKind.text);
    expect(content.text, contains('café'));
    expect(content.text, isNot(contains('�')));
  });

  test('a sparse cp1252 file (classified text) has its mojibake fixed', () async {
    // Mostly ASCII with a lone 0x92 smart quote — few enough replacements to
    // classify as text, but still worth repairing to the real curly quote.
    final raw = <int>[
      ...utf8.encode('the plan is done'),
      0x20, 0x92, 0x73, // " ’s"
      0x0A,
    ];
    final content = await _classifyBytes(raw);
    expect(content.kind, FileContentKind.text);
    expect(content.text, contains('’')); // U+2019, cp1252-specific
    expect(content.text, isNot(contains('�')));
  });

  test('a legitimate U+FFFD glyph in valid UTF-8 is left untouched', () async {
    // Mostly ASCII (so it classifies as text) containing one real replacement
    // glyph — valid bytes EF BF BD. Its UTF-8 reading is already correct and
    // must survive verbatim, not be re-decoded to the cp1252 "ï¿½".
    final raw = <int>[
      ...utf8.encode('the replacement char is '),
      0xEF, 0xBF, 0xBD, // a genuine U+FFFD
      ...utf8.encode(' right here\n'),
    ];
    final content = await _classifyBytes(raw);
    expect(content.kind, FileContentKind.text);
    expect(content.text, 'the replacement char is � right here\n');
    expect(content.text, isNot(contains('ï¿½')));
  });

  test('a genuine binary file stays binary', () async {
    // A NUL and assorted control bytes → not single-byte text.
    final raw = <int>[0x89, 0x50, 0x4E, 0x47, 0x00, 0x1A, 0x0A, 0xE9, 0x01];
    final content = await _classifyBytes(raw);
    expect(content.kind, FileContentKind.binary);
  });

  test('clean UTF-8 with real accents is untouched (no fallback)', () async {
    final raw = utf8.encode('café résumé\n');
    final content = await _classifyBytes(raw);
    expect(content.kind, FileContentKind.text);
    expect(content.text, 'café résumé\n');
  });
}
