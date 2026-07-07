import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/features/viewer/text_decoding.dart';

// Builds the string the UTF-8 read path would hand `classify` for a byte
// sequence: decode as UTF-8 with malformed bytes replaced, exactly like the
// executor.
String asUtf8Read(List<int> bytes) =>
    const Utf8Decoder(allowMalformed: true).convert(bytes);

void main() {
  group('normalizeText', () {
    test('strips a leading UTF-8 BOM', () {
      expect(normalizeText('﻿# Title'), '# Title');
    });

    test('leaves a BOM that is not leading untouched', () {
      expect(normalizeText('a﻿b'), 'a﻿b');
    });

    test('normalizes CRLF to LF', () {
      expect(normalizeText('a\r\nb\r\n'), 'a\nb\n');
    });

    test('normalizes lone CR (classic Mac) to LF', () {
      expect(normalizeText('a\rb\rc'), 'a\nb\nc');
    });

    test('does not double-count a CRLF as CR + empty line', () {
      expect(normalizeText('x\r\n\r\ny'), 'x\n\ny');
    });

    test('is a no-op for clean LF text', () {
      expect(normalizeText('already\nclean\n'), 'already\nclean\n');
    });
  });

  group('BOM signature detection', () {
    test('flags the UTF-16LE prefix as seen after a UTF-8 read', () {
      // "Hi" in UTF-16LE with BOM: FF FE 48 00 69 00
      final raw = asUtf8Read([0xFF, 0xFE, 0x48, 0x00, 0x69, 0x00]);
      expect(hasUtf16Or32BomSignature(raw), isTrue);
    });

    test('flags the UTF-16BE prefix', () {
      final raw = asUtf8Read([0xFE, 0xFF, 0x00, 0x48, 0x00, 0x69]);
      expect(hasUtf16Or32BomSignature(raw), isTrue);
    });

    test('flags the UTF-32BE prefix (leading NULs then replacements)', () {
      final raw = asUtf8Read([0x00, 0x00, 0xFE, 0xFF, 0x00, 0x00, 0x00, 0x41]);
      expect(hasUtf16Or32BomSignature(raw), isTrue);
    });

    test('does not flag ordinary UTF-8 text', () {
      expect(hasUtf16Or32BomSignature('plain ascii'), isFalse);
    });
  });

  group('decodeUtf16Or32', () {
    Uint8List b(List<int> v) => Uint8List.fromList(v);

    test('decodes UTF-16LE with BOM, dropping the BOM', () {
      // "Hi" → FF FE 48 00 69 00
      expect(decodeUtf16Or32(b([0xFF, 0xFE, 0x48, 0x00, 0x69, 0x00])), 'Hi');
    });

    test('decodes UTF-16BE with BOM', () {
      expect(decodeUtf16Or32(b([0xFE, 0xFF, 0x00, 0x48, 0x00, 0x69])), 'Hi');
    });

    test('decodes a UTF-16LE astral char via its surrogate pair', () {
      // U+1F600 GRINNING FACE = surrogate pair D83D DE00; LE bytes 3D D8 00 DE
      final decoded = decodeUtf16Or32(
        b([0xFF, 0xFE, 0x3D, 0xD8, 0x00, 0xDE]),
      );
      expect(decoded, '\u{1F600}');
    });

    test('decodes UTF-32LE with BOM', () {
      // 'A' = U+0041 → 41 00 00 00
      expect(
        decodeUtf16Or32(b([0xFF, 0xFE, 0x00, 0x00, 0x41, 0x00, 0x00, 0x00])),
        'A',
      );
    });

    test('decodes UTF-32BE with BOM', () {
      expect(
        decodeUtf16Or32(b([0x00, 0x00, 0xFE, 0xFF, 0x00, 0x00, 0x00, 0x41])),
        'A',
      );
    });

    test('returns null when no recognised BOM is present', () {
      expect(decodeUtf16Or32(b([0x68, 0x69])), isNull);
    });

    test('ignores a trailing partial code unit rather than throwing', () {
      // Valid "H" then a dangling odd byte.
      expect(decodeUtf16Or32(b([0xFF, 0xFE, 0x48, 0x00, 0x69])), 'H');
    });
  });
}
