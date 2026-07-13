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

/// The line ranges a hunk header declares: `@@ -oldStart,oldCount
/// +newStart,newCount @@`. Counts are optional in the syntax and default to 1
/// (`@@ -5 +5 @@` means one line either side).
///
/// These are what context expansion is computed from — the gap between two
/// hunks is `next.newStart - (this.newStart + this.newCount)` — so they're
/// parsed rather than left in the header string.
class HunkRange {
  final int oldStart;
  final int oldCount;
  final int newStart;
  final int newCount;

  const HunkRange({
    required this.oldStart,
    required this.oldCount,
    required this.newStart,
    required this.newCount,
  });

  /// One past the last line this hunk covers in the post-image (1-based, so
  /// this is the line number the next hunk's gap begins at).
  int get newEnd => newStart + newCount;
  int get oldEnd => oldStart + oldCount;

  @override
  bool operator ==(Object other) =>
      other is HunkRange &&
      other.oldStart == oldStart &&
      other.oldCount == oldCount &&
      other.newStart == newStart &&
      other.newCount == newCount;

  @override
  int get hashCode => Object.hash(oldStart, oldCount, newStart, newCount);

  @override
  String toString() => '@@ -$oldStart,$oldCount +$newStart,$newCount @@';
}

/// `@@ -a,b +c,d @@ optional section heading`. The counts are optional; a
/// *combined* diff (a merge shown with `--cc`) uses `@@@ -a,b -c,d +e,f @@@`
/// instead and deliberately does NOT match — see [DiffFile.canExpand].
final _hunkHeaderPattern = RegExp(
  r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@',
);

/// Parses a hunk header's ranges, or null if [header] isn't a plain two-sided
/// `@@` header (a combined/merge hunk, or something malformed).
HunkRange? parseHunkHeader(String header) {
  final m = _hunkHeaderPattern.firstMatch(header);
  if (m == null) return null;
  return HunkRange(
    oldStart: int.parse(m.group(1)!),
    // An omitted count means 1 line ("@@ -5 +5 @@"); a count of 0 is legal too
    // (a pure insertion into an empty file) and must survive as 0.
    oldCount: m.group(2) == null ? 1 : int.parse(m.group(2)!),
    newStart: int.parse(m.group(3)!),
    newCount: m.group(4) == null ? 1 : int.parse(m.group(4)!),
  );
}

/// One hunk: its `@@ -a,b +c,d @@` header and the raw body lines beneath it.
class DiffHunk {
  final String header;
  final List<String> lines;

  /// The header's parsed ranges — null for a combined (merge) hunk header,
  /// which this deliberately doesn't understand.
  final HunkRange? range;

  const DiffHunk(this.header, this.lines, {this.range});

  /// How many post-image file lines this hunk's body actually carries — the
  /// added and context lines. Removed lines aren't in the post-image, and a
  /// `\ No newline at end of file` marker is not a file line at all: counting
  /// it would push every expansion below it off by one.
  int get postImageLineCount => lines
      .where(
        (l) =>
            diffLineKind(l) == DiffLineKind.add ||
            diffLineKind(l) == DiffLineKind.context,
      )
      .length;
}

/// How a file was changed — decides whether either side's blob exists, and so
/// whether context can be expanded from it.
enum DiffFileChange { modified, added, deleted, renamed, binary, modeOnly }

/// A parsed single-file unified diff: the header block (everything before the
/// first hunk — `diff --git`, `index`, `---`, `+++`, …) and its hunks.
class DiffFile {
  final List<String> header;
  final List<DiffHunk> hunks;

  /// Pre-image path (`a/…`) and post-image path (`b/…`). They differ for a
  /// rename — expansion must read the post-image blob at [newPath] and the
  /// pre-image at [oldPath], never one path for both.
  final String? oldPath;
  final String? newPath;

  final DiffFileChange change;

  const DiffFile(
    this.header,
    this.hunks, {
    this.oldPath,
    this.newPath,
    this.change = DiffFileChange.modified,
  });

  /// Whether context can be expanded from the post-image blob: we need a
  /// post-image path to read, and every hunk header must have parsed (a
  /// combined merge hunk hasn't, and its line arithmetic doesn't hold).
  bool get canExpand =>
      newPath != null &&
      change != DiffFileChange.deleted &&
      change != DiffFileChange.binary &&
      hunks.isNotEmpty &&
      hunks.every((h) => h.range != null);
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
