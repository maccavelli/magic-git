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
///
/// **Total by contract: this never throws.** The pattern matches `(\d+)` with no
/// length bound, so a header can carry a number too large for a 64-bit int, and
/// `int.parse` would throw `FormatException` on it. That exception had nowhere
/// good to land: on the inline parse path it was raised straight out of a
/// widget's `initState`, and on the background-isolate path the huge diffs take
/// (see `HunkDiffView`/`SplitDiffView`) it completed the parse future with an
/// error nobody was listening for — leaving the pane's spinner up forever.
///
/// A number this code cannot represent is exactly what "malformed" means here,
/// so it takes the null branch the signature already promises, and the caller's
/// existing degradation does the rest: [DiffFile.canExpand] goes false, so the
/// file renders in full and simply cannot expand its context.
HunkRange? parseHunkHeader(String header) {
  final m = _hunkHeaderPattern.firstMatch(header);
  if (m == null) return null;
  final oldStart = int.tryParse(m.group(1)!);
  // An omitted count means 1 line ("@@ -5 +5 @@"); a count of 0 is legal too
  // (a pure insertion into an empty file) and must survive as 0.
  final oldCount = m.group(2) == null ? 1 : int.tryParse(m.group(2)!);
  final newStart = int.tryParse(m.group(3)!);
  final newCount = m.group(4) == null ? 1 : int.tryParse(m.group(4)!);
  if (oldStart == null ||
      oldCount == null ||
      newStart == null ||
      newCount == null) {
    return null;
  }
  return HunkRange(
    oldStart: oldStart,
    oldCount: oldCount,
    newStart: newStart,
    newCount: newCount,
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
  return _parseFileAt(lines, 0, lines.length);
}

/// Parses `lines[from..to)` — one file's diff — into a [DiffFile].
DiffFile? _parseFileAt(List<String> lines, int from, int to) {
  final header = <String>[];
  var i = from;
  while (i < to && !lines[i].startsWith('@@')) {
    header.add(lines[i]);
    i++;
  }
  if (i >= to) return null; // no hunks at all (binary, mode-only, empty)

  final hunks = <DiffHunk>[];
  while (i < to) {
    final hunkHeader = lines[i];
    i++;
    final body = <String>[];
    while (i < to && !lines[i].startsWith('@@')) {
      body.add(lines[i]);
      i++;
    }
    hunks.add(DiffHunk(hunkHeader, body, range: parseHunkHeader(hunkHeader)));
  }
  if (hunks.isEmpty) return null;

  final (oldPath, newPath, change) = _classify(header);
  return DiffFile(
    header,
    hunks,
    oldPath: oldPath,
    newPath: newPath,
    change: change,
  );
}

/// Reads the paths and the kind of change out of a file's header block.
///
/// Paths come from the `---`/`+++` lines rather than `diff --git`, because the
/// latter is ambiguous for paths containing spaces while the former are one
/// path each. `/dev/null` on either side is what marks an add or a delete.
(String?, String?, DiffFileChange) _classify(List<String> header) {
  String? oldPath;
  String? newPath;
  var renamed = false;
  var binary = false;

  for (final line in header) {
    if (line.startsWith('diff --git ') && oldPath == null && newPath == null) {
      // For an ordinary (non-rename) binary diff Git omits ---/+++. Its
      // `diff --git a/X b/X` header still identifies the path. Locate the
      // separator by equality of the two sides rather than splitting on a
      // space, which remains correct for a path such as "a and b.png".
      final payload = line.substring('diff --git '.length);
      if (payload.startsWith('a/')) {
        var split = payload.indexOf(' b/');
        while (split >= 0) {
          final oldCandidate = payload.substring(2, split);
          final newCandidate = payload.substring(split + 3);
          if (oldCandidate == newCandidate) {
            oldPath = oldCandidate;
            newPath = newCandidate;
            break;
          }
          split = payload.indexOf(' b/', split + 1);
        }
      }
    } else if (line.startsWith('--- ')) {
      final p = line.substring(4);
      oldPath = p == '/dev/null' ? null : _stripPathPrefix(p);
    } else if (line.startsWith('+++ ')) {
      final p = line.substring(4);
      newPath = p == '/dev/null' ? null : _stripPathPrefix(p);
    } else if (line.startsWith('rename from ')) {
      renamed = true;
      oldPath = line.substring('rename from '.length);
    } else if (line.startsWith('rename to ')) {
      renamed = true;
      newPath = line.substring('rename to '.length);
    } else if (line.startsWith('Binary files ') ||
        line.startsWith('GIT binary patch')) {
      binary = true;
      // Added/deleted binary notices carry /dev/null. Ordinary and renamed
      // paths were recovered from structural headers above; inspect only the
      // null-side shapes here rather than guessing an ambiguous path split.
      if (line.startsWith('Binary files ') && line.endsWith(' differ')) {
        final sides = line.substring(
          'Binary files '.length,
          line.length - ' differ'.length,
        );
        if (sides.startsWith('/dev/null and ')) {
          oldPath = null;
          newPath = _stripPathPrefix(sides.substring('/dev/null and '.length));
        } else if (sides.endsWith(' and /dev/null')) {
          oldPath = _stripPathPrefix(
            sides.substring(0, sides.length - ' and /dev/null'.length),
          );
          newPath = null;
        }
      }
    }
  }

  final change = switch (null) {
    _ when binary => DiffFileChange.binary,
    _ when oldPath == null && newPath != null => DiffFileChange.added,
    _ when newPath == null && oldPath != null => DiffFileChange.deleted,
    _ when renamed => DiffFileChange.renamed,
    _ when oldPath == null && newPath == null => DiffFileChange.modeOnly,
    _ => DiffFileChange.modified,
  };
  return (oldPath, newPath, change);
}

/// Strips git's `a/`/`b/` prefix and any trailing tab-separated timestamp.
String _stripPathPrefix(String path) {
  var p = path;
  final tab = p.indexOf('\t');
  if (tab >= 0) p = p.substring(0, tab);
  if (p.startsWith('a/') || p.startsWith('b/')) p = p.substring(2);
  return p;
}

/// A whole `git show` patch: the commit preamble (the `commit`/`Author`/`Date`
/// lines and the indented message — everything before the first `diff --git`)
/// followed by one [DiffFile] per file touched.
///
/// A merge commit shown without `-m`/`--cc` has a preamble and NO files, which
/// is a valid, complete result — not a parse failure.
class CommitPatch {
  final List<String> preamble;
  final List<DiffFile> files;
  const CommitPatch(this.preamble, this.files);
}

/// Splits a full `git show` patch into its preamble and per-file diffs. Files
/// that carry no hunks (binary, mode-only) are kept — they still render, they
/// just can't expand.
CommitPatch parseCommitPatch(String raw) {
  final lines = raw.split('\n');
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();

  // Every file's diff begins at a `diff …` line; the preamble is whatever
  // precedes the first one. A merge shown with `--cc`/`--combined` heads its
  // files with `diff --cc <path>` rather than `diff --git a/… b/…`, so match
  // both — otherwise a merge's files would be swallowed into the preamble and
  // silently never render.
  final starts = <int>[
    for (var i = 0; i < lines.length; i++)
      if (lines[i].startsWith('diff --git ') ||
          lines[i].startsWith('diff --cc ') ||
          lines[i].startsWith('diff --combined '))
        i,
  ];
  if (starts.isEmpty) return CommitPatch(lines, const []);

  final files = <DiffFile>[];
  for (var f = 0; f < starts.length; f++) {
    final from = starts[f];
    final to = f + 1 < starts.length ? starts[f + 1] : lines.length;
    final file = _parseFileAt(lines, from, to);
    if (file != null) {
      files.add(file);
    } else {
      // Hunkless (binary / mode-only): keep it so it still renders.
      final header = lines.sublist(from, to);
      final (oldPath, newPath, change) = _classify(header);
      files.add(
        DiffFile(
          header,
          const [],
          oldPath: oldPath,
          newPath: newPath,
          change: change,
        ),
      );
    }
  }
  return CommitPatch(lines.sublist(0, starts.first), files);
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

enum SelectionPatchUnsupportedReason {
  emptySelection,
  crossHunkSelection,
  nonChangeLine,
  binary,
  modeOnly,
  combinedDiff,
  malformedHunk,
}

sealed class SelectionPatchResult {
  const SelectionPatchResult();
}

final class SelectionPatchBuilt extends SelectionPatchResult {
  final String patch;
  final int selectedLineCount;

  const SelectionPatchBuilt(this.patch, this.selectedLineCount);
}

final class SelectionPatchUnsupported extends SelectionPatchResult {
  final SelectionPatchUnsupportedReason reason;
  final String message;

  const SelectionPatchUnsupported(this.reason, this.message);
}

/// Builds a one-hunk patch for changed row indices from the parsed file.
/// Indices address [DiffHunk.lines], so identities never escape the displayed
/// file/hunk. Unselected removals become context; unselected additions vanish.
SelectionPatchResult buildSelectionPatch(
  DiffFile file,
  Map<int, Set<int>> selectedRowsByHunk,
) {
  if (file.change == DiffFileChange.binary) {
    return const SelectionPatchUnsupported(
      SelectionPatchUnsupportedReason.binary,
      'Binary changes do not have selectable patch lines.',
    );
  }
  if (file.change == DiffFileChange.modeOnly) {
    return const SelectionPatchUnsupported(
      SelectionPatchUnsupportedReason.modeOnly,
      'Mode-only changes do not have selectable content lines.',
    );
  }
  final nonEmpty = selectedRowsByHunk.entries
      .where((entry) => entry.value.isNotEmpty)
      .toList();
  if (nonEmpty.isEmpty) {
    return const SelectionPatchUnsupported(
      SelectionPatchUnsupportedReason.emptySelection,
      'Select at least one added or removed line.',
    );
  }
  if (nonEmpty.length != 1) {
    return const SelectionPatchUnsupported(
      SelectionPatchUnsupportedReason.crossHunkSelection,
      'Line selections cannot cross hunk boundaries.',
    );
  }
  final entry = nonEmpty.single;
  if (entry.key < 0 || entry.key >= file.hunks.length) {
    return const SelectionPatchUnsupported(
      SelectionPatchUnsupportedReason.malformedHunk,
      'The selected hunk no longer exists.',
    );
  }
  final hunk = file.hunks[entry.key];
  final range = hunk.range;
  if (range == null) {
    return SelectionPatchUnsupported(
      hunk.header.startsWith('@@@')
          ? SelectionPatchUnsupportedReason.combinedDiff
          : SelectionPatchUnsupportedReason.malformedHunk,
      hunk.header.startsWith('@@@')
          ? 'Combined merge diffs cannot be line-staged.'
          : 'The hunk header is malformed.',
    );
  }
  final selected = entry.value;
  for (final index in selected) {
    if (index < 0 || index >= hunk.lines.length) {
      return const SelectionPatchUnsupported(
        SelectionPatchUnsupportedReason.malformedHunk,
        'A selected line no longer exists.',
      );
    }
    final kind = diffLineKind(hunk.lines[index]);
    if (kind != DiffLineKind.add && kind != DiffLineKind.remove) {
      return const SelectionPatchUnsupported(
        SelectionPatchUnsupportedReason.nonChangeLine,
        'Only added and removed lines can be selected.',
      );
    }
  }

  final body = <String>[];
  var previousBodyLineEmitted = false;
  for (var index = 0; index < hunk.lines.length; index++) {
    final line = hunk.lines[index];
    switch (diffLineKind(line)) {
      case DiffLineKind.add:
        previousBodyLineEmitted = selected.contains(index);
        if (previousBodyLineEmitted) body.add(line);
      case DiffLineKind.remove:
        body.add(selected.contains(index) ? line : ' ${line.substring(1)}');
        previousBodyLineEmitted = true;
      case DiffLineKind.context:
        body.add(line);
        previousBodyLineEmitted = true;
      case DiffLineKind.noNewline:
        // The marker describes the immediately preceding +/- line. If that
        // addition was omitted from the selected patch, its marker must be
        // omitted too or `git apply` sees it attached to the wrong row.
        if (previousBodyLineEmitted) body.add(line);
        previousBodyLineEmitted = false;
      case DiffLineKind.other:
        return const SelectionPatchUnsupported(
          SelectionPatchUnsupportedReason.malformedHunk,
          'The hunk contains an unrecognized line.',
        );
    }
  }
  final oldCount = body.where((line) {
    final kind = diffLineKind(line);
    return kind == DiffLineKind.context || kind == DiffLineKind.remove;
  }).length;
  final newCount = body.where((line) {
    final kind = diffLineKind(line);
    return kind == DiffLineKind.context || kind == DiffLineKind.add;
  }).length;
  final suffix = hunk.header.substring(
    _hunkHeaderPattern.firstMatch(hunk.header)!.end,
  );
  final header =
      '@@ -${range.oldStart},$oldCount +${range.newStart},$newCount @@$suffix';
  final buffer = StringBuffer();
  for (final line in file.header) {
    buffer
      ..write(line)
      ..write('\n');
  }
  buffer
    ..write(header)
    ..write('\n');
  for (final line in body) {
    buffer
      ..write(line)
      ..write('\n');
  }
  return SelectionPatchBuilt(buffer.toString(), selected.length);
}
