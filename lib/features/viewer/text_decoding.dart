/// Text-normalisation and non-UTF-8 decoding helpers for the file viewer.
///
/// The read path (`GitService.readFile`) decodes stdout as UTF-8 with malformed
/// bytes replaced, which is right for the common case but leaves four rough
/// edges the viewer has to smooth over: a byte-order mark sitting at the front
/// of the text, Windows/classic-Mac line endings, files that aren't UTF-8 at all
/// (UTF-16/UTF-32), and single-byte legacy charsets (Latin-1 / Windows-1252)
/// whose high bytes fail the UTF-8 decode. These helpers handle all four.
library;

import 'dart:convert';
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
  if (s.isEmpty) return s;
  final hasBom = s.codeUnitAt(0) == 0xFEFF;
  // Zero-copy fast path for the overwhelmingly common Unix-LF-without-BOM file:
  // one native scan for a CR, and if there's none (and no BOM) return `s`
  // unchanged rather than the two chained `replaceAll`s + `substring` a rewrite
  // would allocate.
  if (!hasBom && !s.contains('\r')) return s;
  final buf = StringBuffer();
  for (var i = hasBom ? 1 : 0; i < s.length; i++) {
    final u = s.codeUnitAt(i);
    if (u == 0x0D) {
      // CR (classic Mac) or CRLF (Windows) → a single LF; skip a following LF so
      // CRLF collapses to one, not two.
      buf.writeCharCode(0x0A);
      if (i + 1 < s.length && s.codeUnitAt(i + 1) == 0x0A) i++;
    } else {
      buf.writeCharCode(u);
    }
  }
  return buf.toString();
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
  // Presized to the exact code-unit count (one per byte pair) rather than a
  // growable List<int> that reallocates by doubling and boxes its elements.
  final units = Uint16List((bytes.length - start) >> 1);
  var j = 0;
  for (var i = start; i + 1 < bytes.length; i += 2) {
    units[j++] = littleEndian
        ? bytes[i] | (bytes[i + 1] << 8)
        : (bytes[i] << 8) | bytes[i + 1];
  }
  return String.fromCharCodes(units);
}

String _decode32(Uint8List bytes, int start, {required bool littleEndian}) {
  final points = Uint32List((bytes.length - start) >> 2);
  var j = 0;
  for (var i = start; i + 3 < bytes.length; i += 4) {
    points[j++] = littleEndian
        ? bytes[i] |
              (bytes[i + 1] << 8) |
              (bytes[i + 2] << 16) |
              (bytes[i + 3] << 24)
        : (bytes[i] << 24) |
              (bytes[i + 1] << 16) |
              (bytes[i + 2] << 8) |
              bytes[i + 3];
  }
  return String.fromCharCodes(points);
}

/// Whether [raw] — a file already decoded as UTF-8-with-replacement — looks like
/// a single-byte encoding (Latin-1 / Windows-1252) that was mis-decoded, and so
/// is worth re-reading and decoding with [decodeLatin1] rather than shown as
/// mojibake.
///
/// True only when every non-ASCII code unit is a `U+FFFD` replacement (the UTF-8
/// decode salvaged no real multi-byte character), at least one such replacement
/// is present, and there are no stray C0 control bytes (tab/newline/CR aside).
/// The "no real high char survived" rule is the safety catch: a file that is
/// genuinely (mostly) UTF-8 — including one with real accents plus a lone
/// corrupt byte — keeps a valid high char in its decode, so it fails this test
/// and is left as its correct UTF-8 reading rather than wholesale re-decoded
/// (which would mangle every real multi-byte sequence). Genuine binary is
/// excluded too: it is saturated with C0 control bytes.
///
/// A single-byte file whose high bytes happen to form a valid UTF-8 sequence (so
/// a real char survives) is deliberately *not* caught — a rare coincidence where
/// keeping the UTF-8 reading is the safe choice. And a file that merely contains
/// a literal `U+FFFD` glyph passes this test but is spared by the caller's
/// [isValidUtf8] check (its bytes decode cleanly, so its UTF-8 reading is right).
bool looksLikeLatin1Misdecode(String raw) {
  // Fast path: no replacement char means nothing failed to decode — the text is
  // already clean UTF-8 (or ASCII), so there is nothing to re-decode.
  if (!raw.contains('\uFFFD')) return false;
  var sawReplacement = false;
  for (var i = 0; i < raw.length; i++) {
    final u = raw.codeUnitAt(i);
    if (u == 0xFFFD) {
      sawReplacement = true;
      continue;
    }
    // A real non-ASCII char survived the decode → not a pure single-byte
    // mis-decode; leave the file as its (correct) UTF-8 interpretation.
    if (u > 0x7F) return false;
    // A stray C0 control (NUL et al.; tab/newline/CR excepted) is a binary
    // signal, not single-byte text.
    if (u < 0x20 && u != 0x09 && u != 0x0A && u != 0x0D) return false;
  }
  return sawReplacement;
}

/// Whether [bytes] are valid UTF-8 (strict — no replacement). Used to spare a
/// file that only *looked* mis-decoded because it legitimately contains a
/// `U+FFFD` glyph (encoded as the valid bytes `EF BF BD`): its UTF-8 reading is
/// already correct and must not be re-decoded as a single-byte charset.
bool isValidUtf8(Uint8List bytes) {
  try {
    utf8.decode(bytes);
    return true;
  } on FormatException {
    return false;
  }
}

/// How much of a candidate single-byte decode to scan for the control-char
/// sanity check, and the fraction of control code points tolerated before the
/// bytes are judged binary rather than text.
const int _latinSniffChars = 8000;
const double _latinControlRatio = 0.02;

/// Windows-1252 mappings for bytes `0x80`–`0x9F` — the only range where it
/// differs from Latin-1 (it fills the C1 slots with printable punctuation: smart
/// quotes, dashes, the euro sign, …). The five slots left undefined by the
/// standard (`0x81 0x8D 0x8F 0x90 0x9D`) map to the raw byte value, i.e. a C1
/// control that the decode's own control-ratio guard notices if such bytes turn
/// out to be common (a sign the content was binary after all).
const List<int> _cp1252High = [
  0x20AC, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, // 80-87
  0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8D, 0x017D, 0x8F, //   88-8F
  0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, // 90-97
  0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x9D, 0x017E, 0x0178, // 98-9F
];

/// Decodes [bytes] as Windows-1252 (a superset of ISO-8859-1 / Latin-1),
/// returning the text — or null when the result doesn't look like text (too many
/// control code points, meaning the bytes were binary after all, not a legacy
/// single-byte charset). Every byte maps to a code point, so unlike UTF-8 there
/// is never a decode failure; the control-ratio check is the only rejection.
///
/// Whether it's worth calling this at all is decided upstream by
/// [looksLikeLatin1Misdecode] (plus an [isValidUtf8] guard); this is just the
/// decode and a final sanity check.
String? decodeLatin1(Uint8List bytes) {
  // Each byte maps to exactly one BMP code unit (cp1252 tops out at U+20AC), so
  // presize a Uint16List rather than growing a StringBuffer char by char.
  final units = Uint16List(bytes.length);
  for (var i = 0; i < bytes.length; i++) {
    final b = bytes[i];
    units[i] = b < 0x80 || b > 0x9F ? b : _cp1252High[b - 0x80];
  }
  final s = String.fromCharCodes(units);
  final window = s.length < _latinSniffChars ? s.length : _latinSniffChars;
  if (window == 0) return null;
  var controls = 0;
  for (var i = 0; i < window; i++) {
    final u = s.codeUnitAt(i);
    final isControl =
        (u < 0x20 && u != 0x09 && u != 0x0A && u != 0x0D) ||
        (u >= 0x7F && u <= 0x9F);
    if (isControl) controls++;
  }
  if (controls / window > _latinControlRatio) return null;
  return s;
}
