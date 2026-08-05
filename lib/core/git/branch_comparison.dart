enum BranchBaseSource {
  user,
  remoteHead,
  forgeDefault,
  localMain,
  localMaster,
  currentFallback,
  detachedFallback,
}

extension BranchBaseSourceLabel on BranchBaseSource {
  String get label => switch (this) {
    BranchBaseSource.user => 'Selected workspace base',
    BranchBaseSource.remoteHead => 'Remote default branch',
    BranchBaseSource.forgeDefault => 'Forge default branch',
    BranchBaseSource.localMain => 'Local main fallback',
    BranchBaseSource.localMaster => 'Local master fallback',
    BranchBaseSource.currentFallback => 'Current branch fallback',
    BranchBaseSource.detachedFallback => 'Detached HEAD fallback',
  };
}

class BranchBaseCandidate {
  final String refName;
  final String displayName;
  final String oid;

  const BranchBaseCandidate({
    required this.refName,
    required this.displayName,
    required this.oid,
  });
}

class BranchBase {
  final String? refName;
  final String displayName;
  final String oid;
  final BranchBaseSource source;
  final bool isFallback;

  const BranchBase({
    required this.refName,
    required this.displayName,
    required this.oid,
    required this.source,
    required this.isFallback,
  });
}

class BranchBaseResolution {
  final BranchBase? base;
  final String? unavailableStoredRef;

  const BranchBaseResolution({this.base, this.unavailableStoredRef});
}

typedef ResolveCommit = Future<String?> Function(String revision);
typedef ResolveRemoteHead = Future<String?> Function(String remote);

/// Deterministic, Git-first base selection. Only [storedRefName] represents a
/// user decision; automatic candidates are never written back by this helper.
Future<BranchBaseResolution> resolveBranchBase({
  required List<BranchBaseCandidate> refs,
  required List<String> remotes,
  required String? currentBranch,
  required String? headOid,
  required String? storedRefName,
  required String? forgeDefaultBranch,
  required ResolveCommit resolveCommit,
  required ResolveRemoteHead resolveRemoteHead,
}) async {
  String? unavailableStoredRef;
  if (storedRefName != null && storedRefName.isNotEmpty) {
    final oid = await resolveCommit('$storedRefName^{commit}');
    if (oid != null && isFullGitOid(oid)) {
      return BranchBaseResolution(
        base: BranchBase(
          refName: storedRefName,
          displayName: _displayRef(storedRefName),
          oid: oid,
          source: BranchBaseSource.user,
          isFallback: false,
        ),
      );
    }
    unavailableStoredRef = storedRefName;
  }

  final preferredRemote = remotes.isEmpty
      ? null
      : (remotes.contains('origin') ? 'origin' : remotes.first);
  if (preferredRemote != null) {
    final remoteHead = await resolveRemoteHead(preferredRemote);
    if (remoteHead != null && remoteHead.isNotEmpty) {
      final candidate = _refByName(refs, remoteHead);
      if (candidate != null && isFullGitOid(candidate.oid)) {
        return BranchBaseResolution(
          base: _baseFromRef(candidate, BranchBaseSource.remoteHead),
          unavailableStoredRef: unavailableStoredRef,
        );
      }
      // Symref exists but the tip is missing from the snapshot (partial fetch,
      // pruned remote-tracking ref, etc.). Resolve the commit OID directly.
      final oid = await resolveCommit('$remoteHead^{commit}');
      if (oid != null && isFullGitOid(oid)) {
        return BranchBaseResolution(
          base: BranchBase(
            refName: remoteHead,
            displayName: _displayRef(remoteHead),
            oid: oid,
            source: BranchBaseSource.remoteHead,
            isFallback: false,
          ),
          unavailableStoredRef: unavailableStoredRef,
        );
      }
    }
  }

  if (forgeDefaultBranch != null && forgeDefaultBranch.isNotEmpty) {
    final local = _refByName(refs, 'refs/heads/$forgeDefaultBranch');
    final remote = preferredRemote == null
        ? null
        : _refByName(refs, 'refs/remotes/$preferredRemote/$forgeDefaultBranch');
    final candidate = local ?? remote;
    if (candidate != null && isFullGitOid(candidate.oid)) {
      return BranchBaseResolution(
        base: _baseFromRef(candidate, BranchBaseSource.forgeDefault),
        unavailableStoredRef: unavailableStoredRef,
      );
    }
  }

  for (final candidate in const [
    ('refs/heads/main', BranchBaseSource.localMain),
    ('refs/heads/master', BranchBaseSource.localMaster),
  ]) {
    final ref = _refByName(refs, candidate.$1);
    if (ref != null && isFullGitOid(ref.oid)) {
      return BranchBaseResolution(
        base: _baseFromRef(ref, candidate.$2, isFallback: true),
        unavailableStoredRef: unavailableStoredRef,
      );
    }
  }

  final currentName = currentBranch;
  if (currentName != null) {
    final current = _refByName(refs, 'refs/heads/$currentName');
    if (current != null && isFullGitOid(current.oid)) {
      return BranchBaseResolution(
        base: _baseFromRef(
          current,
          BranchBaseSource.currentFallback,
          isFallback: true,
        ),
        unavailableStoredRef: unavailableStoredRef,
      );
    }
  }

  if (headOid != null && isFullGitOid(headOid)) {
    return BranchBaseResolution(
      base: BranchBase(
        refName: null,
        displayName: 'Detached HEAD fallback',
        oid: headOid,
        source: BranchBaseSource.detachedFallback,
        isFallback: true,
      ),
      unavailableStoredRef: unavailableStoredRef,
    );
  }
  return BranchBaseResolution(unavailableStoredRef: unavailableStoredRef);
}

BranchBaseCandidate? _refByName(List<BranchBaseCandidate> refs, String? name) {
  if (name == null) return null;
  for (final ref in refs) {
    if (ref.refName == name) return ref;
  }
  return null;
}

BranchBase _baseFromRef(
  BranchBaseCandidate ref,
  BranchBaseSource source, {
  bool isFallback = false,
}) => BranchBase(
  refName: ref.refName,
  displayName: ref.displayName,
  oid: ref.oid,
  source: source,
  isFallback: isFallback,
);

String _displayRef(String refName) => refName
    .replaceFirst('refs/heads/', '')
    .replaceFirst('refs/remotes/', '')
    .replaceFirst('refs/tags/', '');

class BranchReviewSummary {
  final String refName;
  final String shortName;
  final String branchOid;
  final String baseOid;
  final int aheadOfBase;
  final int behindBase;
  final DateTime? lastCommitAt;
  final String? lastAuthorName;
  final String? lastAuthorEmail;

  const BranchReviewSummary({
    required this.refName,
    required this.shortName,
    required this.branchOid,
    required this.baseOid,
    required this.aheadOfBase,
    required this.behindBase,
    this.lastCommitAt,
    this.lastAuthorName,
    this.lastAuthorEmail,
  });

  bool get mergedIntoBase => aheadOfBase == 0;
}

class BranchReviewFailure {
  final String refName;
  final String branchOid;
  final String reasonCode;

  const BranchReviewFailure({
    required this.refName,
    required this.branchOid,
    required this.reasonCode,
  });
}

class BranchReviewBatchResult {
  final Map<String, BranchReviewSummary> summariesByRefName;
  final Map<String, BranchReviewFailure> failuresByRefName;

  const BranchReviewBatchResult({
    this.summariesByRefName = const {},
    this.failuresByRefName = const {},
  });
}

bool isFullGitOid(String value) =>
    RegExp(r'^(?:[0-9a-f]{40}|[0-9a-f]{64})$').hasMatch(value);

/// Collision-free value key over sorted local full-ref/OID pairs.
class BranchRefsFingerprint {
  final String canonical;

  BranchRefsFingerprint(Iterable<({String refName, String oid})> refs)
    : canonical = _canonicalize(refs);

  static String _canonicalize(Iterable<({String refName, String oid})> refs) {
    final sorted = refs.toList()
      ..sort((a, b) {
        final byName = a.refName.compareTo(b.refName);
        return byName != 0 ? byName : a.oid.compareTo(b.oid);
      });
    return sorted.map((ref) => '${ref.refName}\u0000${ref.oid}').join('\u0000');
  }

  @override
  bool operator ==(Object other) =>
      other is BranchRefsFingerprint && other.canonical == canonical;

  @override
  int get hashCode => canonical.hashCode;
}

// ---------------------------------------------------------------------------
// Phase 2 — comparison inspector domain
// ---------------------------------------------------------------------------

/// How the patch between base and branch is computed. Only three-dot is
/// shipped; a future direct two-dot path must opt in explicitly.
enum BranchComparisonMethod { threeDot }

enum ComparisonAncestry { connected, unrelated }

class BranchChangedFile {
  final String status;
  final String path;
  final String? oldPath;
  final int? additions;
  final int? deletions;
  final bool binary;

  const BranchChangedFile({
    required this.status,
    required this.path,
    this.oldPath,
    this.additions,
    this.deletions,
    this.binary = false,
  });
}

class BranchComparisonMetadata {
  final String baseOid;
  final String branchOid;
  final String? mergeBaseOid;
  final ComparisonAncestry ancestry;
  final List<BranchChangedFile> files;
  final int additions;
  final int deletions;
  final bool truncated;
  final BranchComparisonMethod method;

  const BranchComparisonMetadata({
    required this.baseOid,
    required this.branchOid,
    required this.mergeBaseOid,
    required this.ancestry,
    required this.files,
    required this.additions,
    required this.deletions,
    required this.truncated,
    this.method = BranchComparisonMethod.threeDot,
  });

  static BranchComparisonMetadata unrelated({
    required String baseOid,
    required String branchOid,
  }) => BranchComparisonMetadata(
    baseOid: baseOid,
    branchOid: branchOid,
    mergeBaseOid: null,
    ancestry: ComparisonAncestry.unrelated,
    files: const [],
    additions: 0,
    deletions: 0,
    truncated: false,
  );
}

/// Default file-list cap for comparison metadata before [truncated] is set.
const int kBranchComparisonMaxFiles = 500;

/// Parses `git diff --name-status -z` output into ordered path records.
///
/// Ordinary: `STATUS\0path\0`. Rename/copy: `STATUS\0old\0new\0` (status may
/// include a similarity score, e.g. `R100`).
List<({String status, String path, String? oldPath})> parseNameStatusZ(
  String raw,
) {
  final out = <({String status, String path, String? oldPath})>[];
  final parts = raw.split('\u0000');
  var i = 0;
  while (i < parts.length) {
    final status = parts[i];
    if (status.isEmpty) {
      i++;
      continue;
    }
    final code = status[0];
    if ((code == 'R' || code == 'C') && i + 2 < parts.length) {
      out.add((status: status, path: parts[i + 2], oldPath: parts[i + 1]));
      i += 3;
      continue;
    }
    if (i + 1 < parts.length) {
      out.add((status: status, path: parts[i + 1], oldPath: null));
      i += 2;
      continue;
    }
    break;
  }
  return out;
}

/// Parses `git diff --numstat -z` into path → (add, del, binary).
///
/// Ordinary: `added\tdeleted\tpath\0`. With renames under `-z`, git emits
/// `added\tdeleted\0old\0new\0` (no path on the first field). Binary files use
/// `-` for both counts.
Map<String, ({int? additions, int? deletions, bool binary})> parseNumstatZ(
  String raw,
) {
  final out = <String, ({int? additions, int? deletions, bool binary})>{};
  final parts = raw.split('\u0000');
  var i = 0;
  while (i < parts.length) {
    final head = parts[i];
    if (head.isEmpty) {
      i++;
      continue;
    }
    final tabs = head.split('\t');
    if (tabs.length >= 3) {
      final path = tabs.sublist(2).join('\t');
      out[path] = _numstatCounts(tabs[0], tabs[1]);
      i++;
      continue;
    }
    if (tabs.length == 2 && i + 2 < parts.length) {
      // Rename form: counts\0old\0new\0 — index by new path.
      final newPath = parts[i + 2];
      out[newPath] = _numstatCounts(tabs[0], tabs[1]);
      i += 3;
      continue;
    }
    i++;
  }
  return out;
}

({int? additions, int? deletions, bool binary}) _numstatCounts(
  String add,
  String del,
) {
  if (add == '-' || del == '-') {
    return (additions: null, deletions: null, binary: true);
  }
  return (
    additions: int.tryParse(add),
    deletions: int.tryParse(del),
    binary: false,
  );
}

/// Join name-status + numstat into [BranchComparisonMetadata] for a connected
/// history. Applies [maxFiles] truncation to the file list only.
BranchComparisonMetadata assembleComparisonMetadata({
  required String baseOid,
  required String branchOid,
  required String mergeBaseOid,
  required String nameStatusZ,
  required String numstatZ,
  int maxFiles = kBranchComparisonMaxFiles,
}) {
  final names = parseNameStatusZ(nameStatusZ);
  final stats = parseNumstatZ(numstatZ);
  final truncated = names.length > maxFiles;
  final limited = truncated ? names.take(maxFiles).toList() : names;
  final files = <BranchChangedFile>[
    for (final n in limited)
      BranchChangedFile(
        status: n.status,
        path: n.path,
        oldPath: n.oldPath,
        additions: stats[n.path]?.additions,
        deletions: stats[n.path]?.deletions,
        binary: stats[n.path]?.binary ?? false,
      ),
  ];
  var additions = 0;
  var deletions = 0;
  for (final f in files) {
    additions += f.additions ?? 0;
    deletions += f.deletions ?? 0;
  }
  return BranchComparisonMetadata(
    baseOid: baseOid,
    branchOid: branchOid,
    mergeBaseOid: mergeBaseOid,
    ancestry: ComparisonAncestry.connected,
    files: files,
    additions: additions,
    deletions: deletions,
    truncated: truncated,
  );
}

// ---------------------------------------------------------------------------
// Phase 3 — merge-tree preview domain
// ---------------------------------------------------------------------------

/// Whether this host's Git can run modern `merge-tree --write-tree` (≥ 2.38).
/// Loading/error for the version probe live in Riverpod `AsyncValue`, not here.
enum MergePreviewCapability { supported, unsupported }

/// Local prediction for merging [branchOid] into [baseOid] without a worktree.
enum MergePreviewState { clean, conflicts, unrelated, unsupported }

/// Immutable merge-tree result keyed by base/branch OIDs.
class BranchMergePreview {
  final MergePreviewState state;
  final List<String> conflictPaths;
  final String? treeOid;

  const BranchMergePreview({
    required this.state,
    this.conflictPaths = const [],
    this.treeOid,
  });

  static const BranchMergePreview unsupported = BranchMergePreview(
    state: MergePreviewState.unsupported,
  );

  static BranchMergePreview unrelated() => const BranchMergePreview(
    state: MergePreviewState.unrelated,
  );

  static BranchMergePreview clean({required String treeOid}) =>
      BranchMergePreview(state: MergePreviewState.clean, treeOid: treeOid);

  static BranchMergePreview conflicts({
    required String treeOid,
    required List<String> conflictPaths,
  }) => BranchMergePreview(
    state: MergePreviewState.conflicts,
    treeOid: treeOid,
    conflictPaths: conflictPaths,
  );

  bool get hasConflicts => state == MergePreviewState.conflicts;
}

/// Parses `git merge-tree --write-tree --name-only -z --no-messages` stdout.
///
/// Framing (Git ≥ 2.38): first NUL-terminated record is the result tree OID;
/// remaining non-empty NUL records are conflict paths (present only when exit
/// status is 1). Exit code is required: 0 = clean, 1 = conflicts.
///
/// Throws [FormatException] on malformed framing so callers surface an error
/// rather than inventing a clean prediction.
BranchMergePreview parseMergeTreeOutput({
  required int exitCode,
  required String stdout,
}) {
  if (exitCode != 0 && exitCode != 1) {
    throw FormatException(
      'merge-tree exit $exitCode is not a merge prediction',
    );
  }
  final parts = stdout.split('\u0000');
  // Drop trailing empty fields from a final NUL.
  while (parts.isNotEmpty && parts.last.isEmpty) {
    parts.removeLast();
  }
  if (parts.isEmpty) {
    throw const FormatException('merge-tree produced empty stdout');
  }
  final treeOid = parts.first.trim();
  if (!isFullGitOid(treeOid)) {
    throw FormatException('merge-tree tree OID is not a full hash: $treeOid');
  }
  final paths = <String>[
    for (final p in parts.skip(1))
      if (p.isNotEmpty) p,
  ];
  if (exitCode == 0) {
    if (paths.isNotEmpty) {
      throw FormatException(
        'merge-tree exit 0 but listed conflict paths: $paths',
      );
    }
    return BranchMergePreview.clean(treeOid: treeOid);
  }
  // exit 1: conflicts. Paths may be empty for rare directory/file edge cases;
  // still report conflicts so we never present unknown as clean.
  return BranchMergePreview.conflicts(
    treeOid: treeOid,
    conflictPaths: paths,
  );
}
