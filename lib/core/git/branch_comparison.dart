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
    final candidate = _refByName(refs, remoteHead);
    if (candidate != null) {
      return BranchBaseResolution(
        base: _baseFromRef(candidate, BranchBaseSource.remoteHead),
        unavailableStoredRef: unavailableStoredRef,
      );
    }
  }

  if (forgeDefaultBranch != null && forgeDefaultBranch.isNotEmpty) {
    final local = _refByName(refs, 'refs/heads/$forgeDefaultBranch');
    final remote = preferredRemote == null
        ? null
        : _refByName(refs, 'refs/remotes/$preferredRemote/$forgeDefaultBranch');
    final candidate = local ?? remote;
    if (candidate != null) {
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
    if (ref != null) {
      return BranchBaseResolution(
        base: _baseFromRef(ref, candidate.$2, isFallback: true),
        unavailableStoredRef: unavailableStoredRef,
      );
    }
  }

  final currentName = currentBranch;
  if (currentName != null) {
    final current = _refByName(refs, 'refs/heads/$currentName');
    if (current != null) {
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
