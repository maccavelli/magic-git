class GitFileStatus {
  final String path;
  final String? oldPath; // Populated for renames and copies
  final String statusX; // Index (staged) status
  final String statusY; // Working tree (unstaged) status

  /// Whether this entry is a submodule change (the porcelain "sub" field
  /// starts with 'S') rather than an ordinary file change.
  final bool isSubmodule;

  /// Rename/copy similarity percentage (0-100), parsed from the type-2
  /// record's `Xscore` field (e.g. `R100` → 100, `C075` → 75). Null for
  /// non-rename/copy entries — the data was already there in the porcelain
  /// output but previously parsed and discarded without being retained.
  final int? similarity;

  const GitFileStatus({
    required this.path,
    this.oldPath,
    required this.statusX,
    required this.statusY,
    this.isSubmodule = false,
    this.similarity,
  });

  // In porcelain v2 an unmodified position is '.', not a space (v1). Treat both
  // — plus the '?'/'!' untracked/ignored markers — as "no change here".
  static bool _isChange(String code) =>
      code != ' ' && code != '.' && code != '?' && code != '!';

  bool get isStaged => _isChange(statusX);
  bool get isUnstaged => _isChange(statusY);
  bool get isUntracked => statusX == '?';
  bool get isRename => statusX == 'R' || statusY == 'R';
  bool get isCopy => statusX == 'C' || statusY == 'C';
  bool get isUnmerged =>
      statusX == 'U' ||
      statusY == 'U' ||
      (statusX == 'A' && statusY == 'A') ||
      (statusX == 'D' && statusY == 'D');
}

/// Branch context reported by `git status --branch` in porcelain v2 (the
/// `# branch.*` headers).
class GitBranchInfo {
  final String? oid; // Current commit, or null when '(initial)'
  final String? head; // Branch name, or null when detached
  final String? upstream; // Upstream ref (e.g. origin/main), if tracking
  final int ahead;
  final int behind;

  const GitBranchInfo({
    this.oid,
    this.head,
    this.upstream,
    this.ahead = 0,
    this.behind = 0,
  });

  bool get isDetached => head == null;
  bool get hasUpstream => upstream != null;

  /// Field-wise equality — see [GitStatus.contentEquals].
  bool contentEquals(GitBranchInfo other) =>
      oid == other.oid &&
      head == other.head &&
      upstream == other.upstream &&
      ahead == other.ahead &&
      behind == other.behind;
}

/// Full parsed result of a porcelain v2 status: branch context plus per-file
/// changes.
class GitStatus {
  final GitBranchInfo branch;
  final List<GitFileStatus> files;

  /// Raw text of any porcelain record that failed its expected field-count
  /// check and was skipped — e.g. output truncated by a transport hiccup.
  /// Empty in the overwhelming common case (a well-formed record from a
  /// healthy git). Previously such records vanished with zero trace; this at
  /// least makes the drop inspectable instead of silent.
  final List<String> parseWarnings;

  GitStatus({
    required this.branch,
    required this.files,
    this.parseWarnings = const [],
  });

  bool get isClean => files.isEmpty;

  // The partitioned lists are read repeatedly per build (headers, sections,
  // counts). `late final` computes each once on first access and caches it, so
  // rebuilds no longer re-filter the whole file list every time.

  /// Unmerged (conflicted) files, surfaced separately so they don't masquerade
  /// as ordinary staged/unstaged changes.
  late final List<GitFileStatus> conflicted = files
      .where((f) => f.isUnmerged)
      .toList();
  late final List<GitFileStatus> staged = files
      .where((f) => f.isStaged && !f.isUnmerged)
      .toList();
  late final List<GitFileStatus> unstaged = files
      .where((f) => f.isUnstaged && !f.isUntracked && !f.isUnmerged)
      .toList();
  late final List<GitFileStatus> untracked = files
      .where((f) => f.isUntracked)
      .toList();

  bool get hasConflicts => conflicted.isNotEmpty;

  /// Whether [other] describes the exact same repository state — same branch
  /// context and the same file records in the same order. Lets the status
  /// provider hand back the *previous instance* on a no-change refresh, so
  /// identity/select-based listeners (worktree diff-cache invalidation, the
  /// structure-tree gate, diff prefetching) treat it as a no-op instead of
  /// refetching the world on every watcher tick. [parseWarnings] are
  /// deliberately excluded: they describe the transport of one particular
  /// fetch, not the repository state itself.
  bool contentEquals(GitStatus other) {
    if (identical(this, other)) return true;
    if (!branch.contentEquals(other.branch)) return false;
    if (files.length != other.files.length) return false;
    for (var i = 0; i < files.length; i++) {
      final a = files[i];
      final b = other.files[i];
      if (a.path != b.path ||
          a.oldPath != b.oldPath ||
          a.statusX != b.statusX ||
          a.statusY != b.statusY ||
          a.isSubmodule != b.isSubmodule ||
          a.similarity != b.similarity) {
        return false;
      }
    }
    return true;
  }
}

class GitPorcelainParser {
  /// Parses raw NUL-terminated stdout from
  /// `git status --porcelain=v2 --branch -z`.
  ///
  /// This is a pure, top-level-callable function so it can run in a background
  /// isolate via `compute()`, keeping large-repo parsing off the UI thread.
  ///
  /// Record grammar (each record NUL-terminated by `-z`):
  ///   `# branch.oid <sha|(initial)>`
  ///   `# branch.head <name|(detached)>`
  ///   `# branch.upstream <ref>`
  ///   `# branch.ab +<ahead> -<behind>`
  ///   `1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>`              (ordinary)
  ///   `2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <Xscore> <path>` NUL `<origPath>`
  ///   `u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>`    (unmerged)
  ///   `? <path>`                                                  (untracked)
  ///   `! <path>`                                                  (ignored)
  static GitStatus parseV2(String rawOutput) {
    String? oid;
    String? head;
    String? upstream;
    int ahead = 0;
    int behind = 0;
    final List<GitFileStatus> files = [];
    final List<String> warnings = [];

    if (rawOutput.isEmpty) {
      return GitStatus(branch: const GitBranchInfo(), files: const []);
    }

    // Split on NUL. A type-2 (rename/copy) entry spans two records — the entry
    // itself and the following original-path record — so we index manually.
    final records = rawOutput.split('\u0000');

    int i = 0;
    while (i < records.length) {
      final record = records[i];
      if (record.isEmpty) {
        i++;
        continue;
      }

      final marker = record[0];
      switch (marker) {
        case '#':
          // `# branch.<key> <value...>` — value may contain spaces (a branch
          // name can), so split into at most three parts.
          final parts = record.split(' ');
          if (parts.length >= 3) {
            final key = parts[1];
            final value = parts.sublist(2).join(' ');
            switch (key) {
              case 'branch.oid':
                oid = value == '(initial)' ? null : value;
                break;
              case 'branch.head':
                head = value == '(detached)' ? null : value;
                break;
              case 'branch.upstream':
                upstream = value;
                break;
              case 'branch.ab':
                // Format: "+<ahead> -<behind>"
                for (final token in value.split(' ')) {
                  if (token.startsWith('+')) {
                    ahead = int.tryParse(token.substring(1)) ?? 0;
                  } else if (token.startsWith('-')) {
                    behind = int.tryParse(token.substring(1)) ?? 0;
                  }
                }
                break;
            }
          }
          i++;
          break;

        case '1':
          // `1 XY sub mH mI mW hH hI path` — 8 fixed fields then the path
          // (which may contain spaces), so cap the split at 9 pieces.
          final fields = record.split(' ');
          if (fields.length >= 9) {
            final xy = fields[1];
            final path = _joinFrom(fields, 8);
            files.add(
              GitFileStatus(
                path: path,
                statusX: xy[0],
                statusY: xy.length > 1 ? xy[1] : ' ',
                isSubmodule: fields[2].startsWith('S'),
              ),
            );
          } else {
            // Truncated/malformed — an environmental issue (transport
            // hiccup), not a code bug, so this is recorded rather than
            // asserted: the rest of the status should still render.
            warnings.add(record);
          }
          i++;
          break;

        case '2':
          // `2 XY sub mH mI mW hH hI Xscore path` then a separate record with
          // the original path.
          final fields = record.split(' ');
          if (fields.length >= 10) {
            final xy = fields[1];
            final path = _joinFrom(fields, 9);
            // A well-formed rename/copy record is always immediately followed
            // by its old-path record; a stream truncated right after this
            // record's own fields (plausible over a live SSH channel) means
            // that pairing never arrives — record it as a warning rather than
            // silently emitting a rename with a null old path. `split(' ')`
            // always yields a trailing '' element, so when this type-2 record is
            // the last real record the "next" record is that empty string — an
            // empty old-path is never valid (a rename always has a source), so
            // treat it as MISSING (warn + null) rather than a real empty path.
            final nextRecord = i + 1 < records.length ? records[i + 1] : null;
            final hasOldPath = nextRecord != null && nextRecord.isNotEmpty;
            final oldPath = hasOldPath ? nextRecord : null;
            if (!hasOldPath) warnings.add(record);
            files.add(
              GitFileStatus(
                path: path,
                oldPath: oldPath,
                statusX: xy[0],
                statusY: xy.length > 1 ? xy[1] : ' ',
                isSubmodule: fields[2].startsWith('S'),
                similarity: _parseSimilarity(fields[8]),
              ),
            );
            i += hasOldPath ? 2 : 1;
          } else {
            warnings.add(record);
            i++;
          }
          break;

        case 'u':
          // `u XY sub m1 m2 m3 mW h1 h2 h3 path` — 10 fixed fields then path.
          final fields = record.split(' ');
          if (fields.length >= 11) {
            final xy = fields[1];
            final path = _joinFrom(fields, 10);
            files.add(
              GitFileStatus(
                path: path,
                statusX: xy[0],
                statusY: xy.length > 1 ? xy[1] : ' ',
                isSubmodule: fields[2].startsWith('S'),
              ),
            );
          } else {
            warnings.add(record);
          }
          i++;
          break;

        case '?':
          // `? path`. Length-guard the substring(2) the way the 1/2/u branches
          // guard their field counts: a truncated record shorter than "? x"
          // would otherwise throw RangeError and abort the whole status parse.
          if (record.length < 3) {
            warnings.add(record);
            i++;
            break;
          }
          files.add(
            GitFileStatus(
              path: record.substring(2),
              statusX: '?',
              statusY: '?',
            ),
          );
          i++;
          break;

        case '!':
          // Ignored entries are surfaced only with --ignored; skip by default.
          i++;
          break;

        default:
          i++;
          break;
      }
    }

    return GitStatus(
      branch: GitBranchInfo(
        oid: oid,
        head: head,
        upstream: upstream,
        ahead: ahead,
        behind: behind,
      ),
      files: files,
      parseWarnings: warnings,
    );
  }

  /// Rejoins the trailing path fields (from index [start]) that a naive
  /// space-split would have fragmented. Leading fixed-width fields never contain
  /// spaces, so everything from [start] onward is the path.
  static String _joinFrom(List<String> fields, int start) =>
      fields.sublist(start).join(' ');

  /// Parses a type-2 record's `Xscore` field (e.g. `R100`, `C075`) into its
  /// similarity percentage. Null if the field is empty or not in that shape.
  static int? _parseSimilarity(String scoreField) {
    if (scoreField.length < 2) return null;
    return int.tryParse(scoreField.substring(1));
  }
}
