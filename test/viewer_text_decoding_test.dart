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

    test('returns the identical instance (zero-copy) for clean LF text', () {
      const s = 'no carriage returns\nand no leading bom\n';
      expect(identical(normalizeText(s), s), isTrue);
    });

    test('empty string is returned unchanged', () {
      expect(normalizeText(''), '');
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
      final decoded = decodeUtf16Or32(b([0xFF, 0xFE, 0x3D, 0xD8, 0x00, 0xDE]));
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

  group('looksLikeLatin1Misdecode', () {
    test('flags a Latin-1 file (accent byte became a replacement)', () {
      // "café\n" in Latin-1: 63 61 66 E9 0A — 0xE9 is invalid UTF-8 alone.
      final raw = asUtf8Read([0x63, 0x61, 0x66, 0xE9, 0x0A]);
      expect(looksLikeLatin1Misdecode(raw), isTrue);
    });

    test(
      'flags a Windows-1252 file (smart-quote byte became a replacement)',
      () {
        // "it's" with a 0x92 curly apostrophe: 69 74 92 73.
        final raw = asUtf8Read([0x69, 0x74, 0x92, 0x73]);
        expect(looksLikeLatin1Misdecode(raw), isTrue);
      },
    );

    test('does not flag clean ASCII', () {
      expect(looksLikeLatin1Misdecode('plain ascii\n'), isFalse);
    });

    test('does not flag valid UTF-8 with real accents (no replacement)', () {
      // "café" as proper UTF-8 → decodes to a real é, no replacement char.
      final raw = asUtf8Read([0x63, 0x61, 0x66, 0xC3, 0xA9]);
      expect(looksLikeLatin1Misdecode(raw), isFalse);
    });

    test('does not flag a mostly-UTF-8 file with one corrupt byte', () {
      // A real é (C3 A9) survives alongside a lone bad byte (E9) → a valid high
      // char remains, so re-decoding would mangle it. Leave it as UTF-8.
      final raw = asUtf8Read([0x63, 0xC3, 0xA9, 0x20, 0xE9, 0x0A]);
      expect(looksLikeLatin1Misdecode(raw), isFalse);
    });

    test('does not flag binary (stray C0 control bytes present)', () {
      // A NUL/other C0 control alongside replacements is a binary signal.
      final raw = asUtf8Read([0x41, 0x00, 0xE9, 0x01, 0xFF]);
      expect(looksLikeLatin1Misdecode(raw), isFalse);
    });
  });

  group('isValidUtf8', () {
    Uint8List b(List<int> v) => Uint8List.fromList(v);

    test('true for valid UTF-8 bytes', () {
      expect(isValidUtf8(b([0x63, 0x61, 0x66, 0xC3, 0xA9])), isTrue);
    });

    test('true for a legitimately-encoded U+FFFD glyph (EF BF BD)', () {
      expect(isValidUtf8(b([0x61, 0xEF, 0xBF, 0xBD])), isTrue);
    });

    test('false for a lone high byte (Latin-1)', () {
      expect(isValidUtf8(b([0x63, 0x61, 0x66, 0xE9])), isFalse);
    });
  });

  group('decodeLatin1', () {
    Uint8List b(List<int> v) => Uint8List.fromList(v);

    test('decodes Latin-1 high bytes to their code points', () {
      expect(decodeLatin1(b([0x63, 0x61, 0x66, 0xE9, 0x0A])), 'café\n');
    });

    test('decodes Windows-1252 punctuation, not Latin-1 C1 controls', () {
      // 0x92 → U+2019 (right single quote) in cp1252, not U+0092.
      expect(decodeLatin1(b([0x69, 0x74, 0x92, 0x73])), 'it’s');
    });

    test('maps the euro sign (0x80 → U+20AC)', () {
      expect(decodeLatin1(b([0x80])), '€');
    });

    test('returns null for control-saturated (binary) bytes', () {
      // Mostly C0 control bytes → too many controls to be single-byte text.
      final bytes = b(List<int>.generate(100, (i) => i.isEven ? 0x01 : 0xE9));
      expect(decodeLatin1(bytes), isNull);
    });
  });
}
