/// Pure Review-mode search, facet, and sort helpers for the Branches workspace.
///
/// No providers, no Git — unit-tested without an executor.
library;

import '../forge/branch_forge_status.dart';
import 'branch_comparison.dart';
import 'git_service.dart';

/// Policy: local branches with no commit activity for this many days are
/// "stale" (current HEAD is never stale). Matches UI copy ("no commit in 3 months").
const int kBranchStaleDays = 90;

/// Whether [branch] is stale relative to [now] using [GitRef.creatorDate].
///
/// Current HEAD is never stale. Missing creator dates are not stale.
///
/// The single definition: `branch_dashboard_stats.dart` re-exports this rather
/// than keeping its own copy. Two byte-identical copies used to exist, which
/// compiled only because no library imported both — the moment one did, the
/// name became an ambiguous import.
bool isBranchStale(
  GitRef branch, {
  DateTime? now,
  int staleDays = kBranchStaleDays,
}) {
  if (branch.isHead) return false;
  final c = branch.creatorDate;
  if (c == null) return false;
  final then = DateTime.fromMillisecondsSinceEpoch(c * 1000);
  final age = (now ?? DateTime.now()).difference(then);
  return age.inDays > staleDays;
}

/// Status tokens accepted by `status:<token>` search terms.
const Set<String> kBranchStatusSearchTokens = {
  'current',
  'pinned',
  'stale',
  'merged',
  'conflict',
  'unpublished',
  'upstream-gone',
  'worktree',
  'ci-failing',
  'request',
  'no-request',
};

sealed class BranchSearchToken {
  const BranchSearchToken();
}

class PlainSearchToken extends BranchSearchToken {
  final String text;
  const PlainSearchToken(this.text);
}

class AuthorSearchToken extends BranchSearchToken {
  final String text;
  const AuthorSearchToken(this.text);
}

class StatusSearchToken extends BranchSearchToken {
  final String status;
  const StatusSearchToken(this.status);
}

/// Parses free-text Review search into typed tokens.
///
/// Grammar:
/// - `author:<text>` — author name/email (case-insensitive substring)
/// - `status:<token>` — one of [kBranchStatusSearchTokens]
/// - unknown `key:value` falls back to plain text (never dropped)
/// - remaining words are plain text (name, subject, request title/number)
List<BranchSearchToken> parseBranchSearchQuery(String raw) {
  final out = <BranchSearchToken>[];
  for (final part in raw.trim().split(RegExp(r'\s+'))) {
    if (part.isEmpty) continue;
    final colon = part.indexOf(':');
    if (colon > 0) {
      final key = part.substring(0, colon).toLowerCase();
      final value = part.substring(colon + 1);
      if (key == 'author' && value.isNotEmpty) {
        out.add(AuthorSearchToken(value));
        continue;
      }
      if (key == 'status' && value.isNotEmpty) {
        final token = value.toLowerCase();
        if (kBranchStatusSearchTokens.contains(token)) {
          out.add(StatusSearchToken(token));
          continue;
        }
      }
      // Unknown key:value → plain text (including the colon).
    }
    out.add(PlainSearchToken(part));
  }
  return out;
}

/// Natural comparison: numeric path segments compare numerically so
/// `release/9` sorts before `release/10`.
int compareNaturalBranchName(String a, String b) {
  final pa = _naturalParts(a);
  final pb = _naturalParts(b);
  final n = pa.length < pb.length ? pa.length : pb.length;
  for (var i = 0; i < n; i++) {
    final ca = pa[i];
    final cb = pb[i];
    final na = int.tryParse(ca);
    final nb = int.tryParse(cb);
    if (na != null && nb != null) {
      final c = na.compareTo(nb);
      if (c != 0) return c;
      continue;
    }
    final c = ca.toLowerCase().compareTo(cb.toLowerCase());
    if (c != 0) return c;
  }
  return pa.length.compareTo(pb.length);
}

List<String> _naturalParts(String s) {
  final out = <String>[];
  final buf = StringBuffer();
  var inDigit = false;
  for (var i = 0; i < s.length; i++) {
    final ch = s[i];
    final digit = ch.codeUnitAt(0) >= 0x30 && ch.codeUnitAt(0) <= 0x39;
    if (buf.isEmpty) {
      inDigit = digit;
      buf.write(ch);
      continue;
    }
    if (digit == inDigit) {
      buf.write(ch);
    } else {
      out.add(buf.toString());
      buf.clear();
      inDigit = digit;
      buf.write(ch);
    }
  }
  if (buf.isNotEmpty) out.add(buf.toString());
  return out;
}

/// Explicit Review sorts. [smart] is the default attention order.
enum BranchReviewSortMode { smart, activity, name, ahead, behind }

/// Facets compose by AND. A null/absent optional knowledge does not match
/// negative facets (`noRequest` only matches known-empty forge data).
class BranchReviewFacets {
  final bool? mergedIntoBase; // true=merged, false=not merged, null=any
  final bool? stale; // true=stale, false=active
  final bool? hasRequest; // true=open request, false=no request (known only)
  final bool failingCi;
  final bool unpublished;
  final bool upstreamGone;
  final bool worktree;
  final bool conflict; // known conflicts only
  final bool mine;

  const BranchReviewFacets({
    this.mergedIntoBase,
    this.stale,
    this.hasRequest,
    this.failingCi = false,
    this.unpublished = false,
    this.upstreamGone = false,
    this.worktree = false,
    this.conflict = false,
    this.mine = false,
  });

  BranchReviewFacets copyWith({
    bool? mergedIntoBase,
    bool clearMerged = false,
    bool? stale,
    bool clearStale = false,
    bool? hasRequest,
    bool clearHasRequest = false,
    bool? failingCi,
    bool? unpublished,
    bool? upstreamGone,
    bool? worktree,
    bool? conflict,
    bool? mine,
  }) => BranchReviewFacets(
    mergedIntoBase: clearMerged
        ? null
        : (mergedIntoBase ?? this.mergedIntoBase),
    stale: clearStale ? null : (stale ?? this.stale),
    hasRequest: clearHasRequest ? null : (hasRequest ?? this.hasRequest),
    failingCi: failingCi ?? this.failingCi,
    unpublished: unpublished ?? this.unpublished,
    upstreamGone: upstreamGone ?? this.upstreamGone,
    worktree: worktree ?? this.worktree,
    conflict: conflict ?? this.conflict,
    mine: mine ?? this.mine,
  );

  int get activeCount {
    var n = 0;
    if (mergedIntoBase != null) n++;
    if (stale != null) n++;
    if (hasRequest != null) n++;
    if (failingCi) n++;
    if (unpublished) n++;
    if (upstreamGone) n++;
    if (worktree) n++;
    if (conflict) n++;
    if (mine) n++;
    return n;
  }

  bool get isEmpty => activeCount == 0;
}

/// Inputs needed to evaluate facets/search against one local branch.
class BranchReviewRowContext {
  final GitRef branch;
  final BranchReviewSummary? summary;
  final BranchForge? forge;
  final bool forgeKnown; // false => forge data unavailable (not empty)
  final bool pinned;
  final bool conflictKnown;
  final String? committerEmail; // normalized lower, or null
  final String? committerName; // normalized lower, or null

  const BranchReviewRowContext({
    required this.branch,
    this.summary,
    this.forge,
    this.forgeKnown = true,
    this.pinned = false,
    this.conflictKnown = false,
    this.committerEmail,
    this.committerName,
  });
}

/// [now] is threaded so staleness is testable against a pinned clock rather
/// than the wall clock.
bool matchesBranchReviewFacets(
  BranchReviewRowContext ctx,
  BranchReviewFacets facets, {
  DateTime? now,
}) {
  final b = ctx.branch;
  if (facets.mergedIntoBase != null) {
    final merged = ctx.summary?.mergedIntoBase ?? false;
    if (merged != facets.mergedIntoBase) return false;
  }
  if (facets.stale != null) {
    if (isBranchStale(b, now: now) != facets.stale) return false;
  }
  if (facets.hasRequest != null) {
    // Negative "no request" requires known forge data.
    if (!ctx.forgeKnown) return false;
    final has = ctx.forge?.hasRequest ?? false;
    if (has != facets.hasRequest) return false;
  }
  if (facets.failingCi) {
    if (!ctx.forgeKnown) return false;
    if (ctx.forge?.ci != ForgeCi.failure) return false;
  }
  if (facets.unpublished) {
    if (b.upstream != null && !b.upstreamGone) return false;
  }
  if (facets.upstreamGone) {
    if (!b.upstreamGone) return false;
  }
  if (facets.worktree) {
    if (b.worktreePath == null && b.elsewhereWorktreePath == null) {
      return false;
    }
  }
  if (facets.conflict) {
    if (!ctx.conflictKnown) return false;
  }
  if (facets.mine) {
    if (!_matchesMine(ctx)) return false;
  }
  return true;
}

bool _matchesMine(BranchReviewRowContext ctx) {
  final email = ctx.committerEmail;
  final name = ctx.committerName;
  if (email == null && name == null) return false;
  final authorEmail = (ctx.branch.authorEmail ?? '').toLowerCase();
  final authorName = (ctx.branch.authorName ?? '').toLowerCase();
  if (email != null && email.isNotEmpty) {
    return authorEmail == email;
  }
  if (name != null && name.isNotEmpty) {
    return authorName == name;
  }
  return false;
}

bool matchesBranchSearchTokens(
  BranchReviewRowContext ctx,
  List<BranchSearchToken> tokens, {
  DateTime? now,
}) {
  if (tokens.isEmpty) return true;
  for (final t in tokens) {
    switch (t) {
      case PlainSearchToken(:final text):
        if (!_matchesPlain(ctx, text.toLowerCase())) return false;
      case AuthorSearchToken(:final text):
        final q = text.toLowerCase();
        final email = (ctx.branch.authorEmail ?? '').toLowerCase();
        final name = (ctx.branch.authorName ?? '').toLowerCase();
        if (!email.contains(q) && !name.contains(q)) return false;
      case StatusSearchToken(:final status):
        if (!_matchesStatus(ctx, status, now: now)) return false;
    }
  }
  return true;
}

bool _matchesPlain(BranchReviewRowContext ctx, String q) {
  if (q.isEmpty) return true;
  final b = ctx.branch;
  if (b.shortName.toLowerCase().contains(q)) return true;
  if (b.subject.toLowerCase().contains(q)) return true;
  final f = ctx.forge;
  if (f != null) {
    if (f.requestLabel.toLowerCase().contains(q)) return true;
    if ((f.requestTitle ?? '').toLowerCase().contains(q)) return true;
    if ('${f.requestNumber}'.contains(q)) return true;
  }
  return false;
}

bool _matchesStatus(BranchReviewRowContext ctx, String status, {DateTime? now}) {
  final b = ctx.branch;
  return switch (status) {
    'current' => b.isHead,
    'pinned' => ctx.pinned,
    'stale' => isBranchStale(b, now: now),
    'merged' => ctx.summary?.mergedIntoBase ?? false,
    'conflict' => ctx.conflictKnown,
    'unpublished' => b.upstream == null || b.upstreamGone,
    'upstream-gone' => b.upstreamGone,
    'worktree' =>
      b.worktreePath != null || b.elsewhereWorktreePath != null,
    'ci-failing' => ctx.forgeKnown && ctx.forge?.ci == ForgeCi.failure,
    'request' => ctx.forgeKnown && (ctx.forge?.hasRequest ?? false),
    'no-request' => ctx.forgeKnown && !(ctx.forge?.hasRequest ?? false),
    _ => false,
  };
}

/// Smart attention order (lower = higher priority).
int smartAttentionRank(BranchReviewRowContext ctx) {
  final b = ctx.branch;
  if (ctx.conflictKnown ||
      (ctx.forgeKnown && ctx.forge?.ci == ForgeCi.failure) ||
      b.upstreamGone) {
    return 0;
  }
  if (ctx.forgeKnown && (ctx.forge?.hasRequest ?? false)) return 1;
  final ahead = ctx.summary?.aheadOfBase ?? 0;
  if (b.upstream == null || ahead > 0) return 2;
  if (ctx.summary?.mergedIntoBase ?? false) return 3;
  return 4;
}

int compareBranchReviewRows(
  BranchReviewRowContext a,
  BranchReviewRowContext b,
  BranchReviewSortMode sort,
) {
  switch (sort) {
    case BranchReviewSortMode.smart:
      final ra = smartAttentionRank(a);
      final rb = smartAttentionRank(b);
      if (ra != rb) return ra.compareTo(rb);
      final byDate = (b.branch.creatorDate ?? 0).compareTo(
        a.branch.creatorDate ?? 0,
      );
      if (byDate != 0) return byDate;
      return compareNaturalBranchName(a.branch.shortName, b.branch.shortName);
    case BranchReviewSortMode.activity:
      final byDate = (b.branch.creatorDate ?? 0).compareTo(
        a.branch.creatorDate ?? 0,
      );
      if (byDate != 0) return byDate;
      return compareNaturalBranchName(a.branch.shortName, b.branch.shortName);
    case BranchReviewSortMode.name:
      return compareNaturalBranchName(a.branch.shortName, b.branch.shortName);
    case BranchReviewSortMode.ahead:
      final aa = a.summary?.aheadOfBase ?? -1;
      final ba = b.summary?.aheadOfBase ?? -1;
      final c = ba.compareTo(aa);
      if (c != 0) return c;
      return compareNaturalBranchName(a.branch.shortName, b.branch.shortName);
    case BranchReviewSortMode.behind:
      final ab = a.summary?.behindBase ?? -1;
      final bb = b.summary?.behindBase ?? -1;
      final c = bb.compareTo(ab);
      if (c != 0) return c;
      return compareNaturalBranchName(a.branch.shortName, b.branch.shortName);
  }
}

List<GitRef> shapeReviewBranches({
  required List<GitRef> branches,
  required Map<String, BranchReviewSummary> summaries,
  required Map<String, BranchForge> forge,
  required bool forgeKnown,
  required Set<String> pinnedNames,
  required Set<String> conflictRefNames,
  required BranchReviewFacets facets,
  required BranchReviewSortMode sort,
  required List<BranchSearchToken> search,
  String? committerEmail,
  String? committerName,
}) {
  final rows = <BranchReviewRowContext>[
    for (final branch in branches)
      BranchReviewRowContext(
        branch: branch,
        summary: summaries[branch.name],
        forge: forge[branch.shortName],
        forgeKnown: forgeKnown,
        pinned: pinnedNames.contains(branch.shortName),
        conflictKnown: conflictRefNames.contains(branch.name),
        committerEmail: committerEmail,
        committerName: committerName,
      ),
  ];
  final filtered = [
    for (final row in rows)
      if (matchesBranchReviewFacets(row, facets) &&
          matchesBranchSearchTokens(row, search))
        row,
  ];
  filtered.sort((a, b) => compareBranchReviewRows(a, b, sort));
  return [for (final r in filtered) r.branch];
}

/// Ordered multi-selection of full ref names with an anchor for range ops.
class BranchMultiSelection {
  final List<String> ordered;
  final String? anchor;

  const BranchMultiSelection({this.ordered = const [], this.anchor});

  static const empty = BranchMultiSelection();

  bool get isEmpty => ordered.isEmpty;
  bool get isSingle => ordered.length == 1;
  bool get isMulti => ordered.length > 1;
  int get length => ordered.length;
  Set<String> get asSet => ordered.toSet();
  String? get primary => ordered.isEmpty ? null : ordered.last;

  bool contains(String fullRef) => ordered.contains(fullRef);

  BranchMultiSelection replace(String fullRef) =>
      BranchMultiSelection(ordered: [fullRef], anchor: fullRef);

  BranchMultiSelection toggle(String fullRef) {
    final next = List<String>.of(ordered);
    if (next.contains(fullRef)) {
      next.remove(fullRef);
      return BranchMultiSelection(
        ordered: next,
        anchor: fullRef,
      );
    }
    next.add(fullRef);
    return BranchMultiSelection(ordered: next, anchor: fullRef);
  }

  BranchMultiSelection rangeTo(
    String fullRef,
    List<String> visibleFullRefs,
  ) {
    final start = anchor ?? fullRef;
    final i0 = visibleFullRefs.indexOf(start);
    final i1 = visibleFullRefs.indexOf(fullRef);
    if (i0 < 0 || i1 < 0) return replace(fullRef);
    final lo = i0 < i1 ? i0 : i1;
    final hi = i0 < i1 ? i1 : i0;
    return BranchMultiSelection(
      ordered: visibleFullRefs.sublist(lo, hi + 1),
      anchor: start,
    );
  }

  /// Drop vanished refs after a refresh; re-anchor to nearest surviving row.
  BranchMultiSelection preserveAfterRefresh(
    List<String> survivingVisible,
  ) {
    final surviving = {
      for (final n in ordered)
        if (survivingVisible.contains(n)) n,
    };
    final next = [for (final n in ordered) if (surviving.contains(n)) n];
    if (next.isEmpty) {
      if (survivingVisible.isEmpty) return empty;
      // Prefer nearest to old anchor.
      final a = anchor;
      if (a != null) {
        final idx = survivingVisible.indexOf(a);
        if (idx >= 0) {
          return BranchMultiSelection(
            ordered: [survivingVisible[idx]],
            anchor: survivingVisible[idx],
          );
        }
      }
      return BranchMultiSelection(
        ordered: [survivingVisible.first],
        anchor: survivingVisible.first,
      );
    }
    final newAnchor = (anchor != null && next.contains(anchor))
        ? anchor
        : next.last;
    return BranchMultiSelection(ordered: next, anchor: newAnchor);
  }
}

/// GitLab-style protected-branch `*` matcher.
///
/// `*` alone matches everything; a pattern with no `*` is an exact match;
/// otherwise `*` expands to `.*`, which — matching GitLab — **does cross `/`**,
/// so `release/*` covers `release/1.0` and `release/1.0/hotfix` alike. (This
/// doc previously claimed segment-scoped matching, which the implementation
/// never did.)
bool gitlabProtectedBranchMatches(String pattern, String branchName) {
  if (pattern == '*') return true;
  if (!pattern.contains('*')) return pattern == branchName;
  final escaped = RegExp.escape(pattern).replaceAll(r'\*', '.*');
  return RegExp('^$escaped\$').hasMatch(branchName);
}

/// Whether a branch is protected on the forge — including the case where we
/// simply do not know.
///
/// The third state is the point. Branch protection is the difference between
/// "this delete will fail" and "this delete will succeed", and forges expose
/// it unevenly: GitHub rulesets are invisible to the branches API, GitLab
/// needs a separate call, and either can fail. Reporting unknown as
/// "unprotected" would turn a missing answer into a green light.
sealed class ProtectionKnowledge {
  const ProtectionKnowledge();

  /// The forge answered and named this branch protected.
  const factory ProtectionKnowledge.protected() = ProtectionProtected;

  /// The forge answered and did not name this branch.
  const factory ProtectionKnowledge.unprotected() = ProtectionUnprotected;

  /// No usable answer: the call failed, the forge is unknown, or the repo has
  /// no forge remote.
  const factory ProtectionKnowledge.unknown() = ProtectionUnknown;

  bool get isProtected => this is ProtectionProtected;
  bool get isUnknown => this is ProtectionUnknown;
}

class ProtectionProtected extends ProtectionKnowledge {
  const ProtectionProtected();
}

class ProtectionUnprotected extends ProtectionKnowledge {
  const ProtectionUnprotected();
}

class ProtectionUnknown extends ProtectionKnowledge {
  const ProtectionUnknown();
}

/// A repo's protected-branch rules, or the absence of an answer.
///
/// GitHub returns literal branch names; GitLab returns wildcard patterns. Both
/// land here, and [protectionFor] applies the right matching for each.
class BranchProtectionRules {
  /// Literal branch names (GitHub).
  final Set<String> names;

  /// Wildcard patterns (GitLab), matched with [gitlabProtectedBranchMatches].
  final List<String> patterns;

  /// False when nothing could be fetched — every lookup is then `unknown`.
  final bool known;

  const BranchProtectionRules({
    this.names = const {},
    this.patterns = const [],
    this.known = false,
  });

  static const unavailable = BranchProtectionRules();

  ProtectionKnowledge protectionFor(String shortName) {
    if (!known) return const ProtectionKnowledge.unknown();
    if (names.contains(shortName)) {
      return const ProtectionKnowledge.protected();
    }
    for (final p in patterns) {
      if (gitlabProtectedBranchMatches(p, shortName)) {
        return const ProtectionKnowledge.protected();
      }
    }
    return const ProtectionKnowledge.unprotected();
  }
}
