/// Text-normalisation and non-UTF-8 decoding helpers for the file viewer.
///
/// The read path (`GitService.readFile`) decodes stdout as UTF-8 with malformed
/// bytes replaced, which is right for the common case but leaves three rough
/// edges the viewer has to smooth over: a byte-order mark sitting at the front
/// of the text, Windows/classic-Mac line endings, and files that aren't UTF-8
/// at all (UTF-16/UTF-32). These helpers handle all three.
library;

import 'dart:typed_data';

/// Normalises decoded text for display: strips a leading UTF-8 BOM and collapses
/// CRLF (`\r\n`) and lone-CR (`\r`) line endings to `\n`.
///
/// Both matter to the viewer. A leading `U+FEFF` otherwise leads the document
/// with a zero-width char and, worse, defeats Markdown's ATX-heading match on a
/// first line like `# Title`. A trailing `\r` on every line otherwise doubles
/// row height in the word-wrapped source view (Flutter treats it as a hard
/// break) and pollutes copied text; a classic-Mac `\r`-only file would collapse
/// to a single line entirely.
String normalizeText(String s) {
  var out = s;
  if (out.isNotEmpty && out.codeUnitAt(0) == 0xFEFF) {
    out = out.substring(1);
  }
  // `\r\n` first, then any surviving lone `\r`, so neither pass double-counts.
  return out.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
}

/// The tell-tale prefix a UTF-16/UTF-32 BOM leaves once the file has been
/// decoded as UTF-8 with malformed bytes replaced: the `0xFF`/`0xFE` BOM bytes
/// each become a `U+FFFD` replacement char (UTF-16 LE/BE and UTF-32LE all begin
/// `FF FE`/`FE FF`), while a UTF-32BE BOM (`00 00 FE FF`) begins with two NULs
/// then the two replacements. Used only to decide whether a file already
/// classified *binary* is worth re-reading as bytes and decoding properly —
/// never as the decode itself (see [decodeUtf16Or32]).
bool hasUtf16Or32BomSignature(String raw) {
  int at(int i) => i < raw.length ? raw.codeUnitAt(i) : -1;
  const fffd = 0xFFFD;
  // UTF-16 LE/BE and UTF-32LE: two leading replacement chars.
  if (at(0) == fffd && at(1) == fffd) return true;
  // UTF-32BE (`00 00 FE FF`): two NULs then the two replacements.
  if (at(0) == 0 && at(1) == 0 && at(2) == fffd && at(3) == fffd) return true;
  return false;
}

/// Decodes [bytes] as UTF-16 or UTF-32 when they carry the corresponding BOM,
/// returning the decoded String (BOM removed), or null if no recognised BOM is
/// present. The order matters: UTF-32LE (`FF FE 00 00`) shares its first two
/// bytes with UTF-16LE (`FF FE`), so the 4-byte marks are checked first.
///
/// Dart Strings are UTF-16, so UTF-16 code units (surrogate pairs included) map
/// straight through `String.fromCharCodes`; UTF-32 code points likewise, which
/// re-encodes any astral-plane scalar as a surrogate pair. A trailing partial
/// code unit (odd/!=4-aligned tail) is ignored rather than throwing.
String? decodeUtf16Or32(Uint8List bytes) {
  bool startsWith(List<int> sig) {
    if (bytes.length < sig.length) return false;
    for (var i = 0; i < sig.length; i++) {
      if (bytes[i] != sig[i]) return false;
    }
    return true;
  }

  // UTF-32 (4-byte BOMs) before UTF-16, since FF FE is a prefix of FF FE 00 00.
  if (startsWith([0xFF, 0xFE, 0x00, 0x00])) {
    return _decode32(bytes, 4, littleEndian: true);
  }
  if (startsWith([0x00, 0x00, 0xFE, 0xFF])) {
    return _decode32(bytes, 4, littleEndian: false);
  }
  if (startsWith([0xFF, 0xFE])) {
    return _decode16(bytes, 2, littleEndian: true);
  }
  if (startsWith([0xFE, 0xFF])) {
    return _decode16(bytes, 2, littleEndian: false);
  }
  return null;
}

String _decode16(Uint8List bytes, int start, {required bool littleEndian}) {
  final units = <int>[];
  for (var i = start; i + 1 < bytes.length; i += 2) {
    units.add(
      littleEndian
          ? bytes[i] | (bytes[i + 1] << 8)
          : (bytes[i] << 8) | bytes[i + 1],
    );
  }
  return String.fromCharCodes(units);
}

String _decode32(Uint8List bytes, int start, {required bool littleEndian}) {
  final points = <int>[];
  for (var i = start; i + 3 < bytes.length; i += 4) {
    points.add(
      littleEndian
          ? bytes[i] |
                (bytes[i + 1] << 8) |
                (bytes[i + 2] << 16) |
                (bytes[i + 3] << 24)
          : (bytes[i] << 24) |
                (bytes[i + 1] << 16) |
                (bytes[i + 2] << 8) |
                bytes[i + 3],
    );
  }
  return String.fromCharCodes(points);
}
