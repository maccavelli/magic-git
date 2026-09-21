/// Plain-text cleanup for CI job logs fetched through a forge CLI.
library;

/// Real terminal escape sequences, as ECMA-48 defines them: a CSI sequence
/// (`ESC [` parameter bytes, intermediate bytes, one final byte), an OSC
/// string (`ESC ]` up to BEL or ST), or a two-byte Fe escape. CSI and OSC are
/// tried before Fe, whose range includes the `]` that opens an OSC.
final RegExp _realEscape = RegExp(
  r'\x1B\[[\x30-\x3F]*[\x20-\x2F]*[\x40-\x7E]'
  r'|\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)'
  r'|\x1B[\x40-\x5A\x5C-\x5F]',
);

/// gh's caret rendering of an SGR (`m`) or EL (`K`) sequence: `^[[36;1m`.
///
/// Deliberately narrow. A literal `^[` is ordinary log text, and the full
/// ECMA-48 grammar applied to it eats script content: `'^[[:digit:]]+$'`
/// would lose `^[[:d` and become `'igit:]]+$'`.
final RegExp _caretSgr = RegExp(r'\^\[\[[0-9;]*[mK]');

/// gh's `<job>\t<step>\t` column prefix: two tab-free fields, each followed by
/// a tab.
final RegExp _columnPrefix = RegExp(r'^[^\t\n]*\t[^\t\n]*\t');

const String _bom = '\uFEFF';

/// Cleans the output of `gh run view --job <id> --log` for display.
///
/// gh has rendered every control byte in a run log as caret text since
/// v2.92.0 (cli/cli#13272, "Fix log terminal injection"), so an ESC arrives
/// as the two characters `^[` and a colour code reads as `^[[36;1m`. A host
/// with an older gh sends the real ESC bytes instead. The app runs whichever
/// gh the connected host has, so both forms are handled, as is a future gh
/// that strips them itself.
///
/// Four rules, applied in this order:
///
/// 1. remove real ESC sequences (CSI, OSC and two-byte Fe);
/// 2. remove the caret SGR and EL form `^[[<digits and ;>m` or `…K` only, so
///    literal `^[` text such as `'^[[:digit:]]+$'` survives unchanged;
/// 3. remove the `<a>\t<b>\t` prefix only when every non-empty line starts
///    with the identical pair;
/// 4. remove one U+FEFF at the start of each line's content, after rule 3.
///
/// Nothing else changes: line endings are kept and nothing is trimmed.
String sanitizeGhJobLog(String raw) {
  if (raw.isEmpty) return raw;
  final text = raw.replaceAll(_realEscape, '').replaceAll(_caretSgr, '');
  final lines = text.split('\n');
  final prefix = _uniformPrefix(lines);
  return lines.map((line) => _cleanLine(line, prefix)).join('\n');
}

/// The `<a>\t<b>\t` prefix shared by every non-empty line, or null when there
/// is no non-empty line, the first has no such prefix, or any line differs.
String? _uniformPrefix(List<String> lines) {
  String? prefix;
  for (final line in lines) {
    if (line.isEmpty) continue;
    if (prefix == null) {
      final match = _columnPrefix.firstMatch(line);
      if (match == null) return null;
      prefix = match.group(0);
    } else if (!line.startsWith(prefix)) {
      return null;
    }
  }
  return prefix;
}

String _cleanLine(String line, String? prefix) {
  final content = prefix != null && line.isNotEmpty
      ? line.substring(prefix.length)
      : line;
  return content.startsWith(_bom) ? content.substring(_bom.length) : content;
}
