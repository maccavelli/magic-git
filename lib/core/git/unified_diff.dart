// Minimal unified-diff model + parser, used for hunk-level staging. Lines are
// kept as raw strings (with their leading ' '/'+'/'-'/'\' marker) so a single
// hunk can be re-emitted byte-for-byte into a patch that `git apply` accepts —
// no reflowing, which git apply is strict about.

/// The kind of a hunk body line, derived from its leading character.
enum DiffLineKind { context, add, remove, noNewline, other }

DiffLineKind diffLineKind(String rawLine) {
  if (rawLine.isEmpty) return DiffLineKind.context; // a bare blank context line
  return switch (rawLine[0]) {
    '+' => DiffLineKind.add,
    '-' => DiffLineKind.remove,
    ' ' => DiffLineKind.context,
    '\\' => DiffLineKind.noNewline, // "\ No newline at end of file"
    _ => DiffLineKind.other,
  };
}

/// One hunk: its `@@ -a,b +c,d @@` header and the raw body lines beneath it.
class DiffHunk {
  final String header;
  final List<String> lines;
  const DiffHunk(this.header, this.lines);
}

/// A parsed single-file unified diff: the header block (everything before the
/// first hunk — `diff --git`, `index`, `---`, `+++`, …) and its hunks.
class DiffFile {
  final List<String> header;
  final List<DiffHunk> hunks;
  const DiffFile(this.header, this.hunks);
}

/// Parses [raw] (a `git diff` for a single file) into a [DiffFile], or null when
/// there is nothing hunk-stageable — an empty diff, or a binary/mode-only change
/// with no `@@` hunks.
DiffFile? parseUnifiedDiff(String raw) {
  if (raw.trim().isEmpty) return null;
  final lines = raw.split('\n');
  // `git diff` output ends with a newline, so split leaves a trailing '' — drop
  // it so it isn't re-emitted as a spurious blank line.
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();

  final header = <String>[];
  var i = 0;
  while (i < lines.length && !lines[i].startsWith('@@')) {
    header.add(lines[i]);
    i++;
  }
  if (i >= lines.length) return null; // no hunks at all

  final hunks = <DiffHunk>[];
  while (i < lines.length) {
    final hunkHeader = lines[i];
    i++;
    final body = <String>[];
    while (i < lines.length && !lines[i].startsWith('@@')) {
      body.add(lines[i]);
      i++;
    }
    hunks.add(DiffHunk(hunkHeader, body));
  }
  return hunks.isEmpty ? null : DiffFile(header, hunks);
}

/// Rebuilds a minimal patch containing [file]'s header and exactly one [hunk],
/// byte-for-byte, terminated with a trailing newline so `git apply` accepts it.
String buildHunkPatch(DiffFile file, DiffHunk hunk) {
  final buf = StringBuffer();
  for (final h in file.header) {
    buf.write(h);
    buf.write('\n');
  }
  buf.write(hunk.header);
  buf.write('\n');
  for (final l in hunk.lines) {
    buf.write(l);
    buf.write('\n');
  }
  return buf.toString();
}
