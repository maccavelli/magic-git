/// Stable kinds understood by the Go to / Do palette.
enum PaletteEntryKind {
  action,
  panel,
  repository,
  branch,
  tag,
  commit,
  changedFile,
  repositoryFile,
  stash,
  worktree,
  issue,
  changeRequest,
  pipeline,
}

/// Top-level intent filters. Entity prefixes may opt into a bounded load;
/// category prefixes only filter entries which have already landed.
enum PaletteQueryScope {
  all,
  go,
  git,
  forge,
  app,
  branch,
  commit,
  file,
  stash,
  worktree,
  issue,
  request,
  ci,
}

class PaletteQuery {
  final PaletteQueryScope scope;
  final String text;

  const PaletteQuery({this.scope = PaletteQueryScope.all, this.text = ''});

  bool get isEntity => switch (scope) {
    PaletteQueryScope.branch ||
    PaletteQueryScope.commit ||
    PaletteQueryScope.file ||
    PaletteQueryScope.stash ||
    PaletteQueryScope.worktree ||
    PaletteQueryScope.issue ||
    PaletteQueryScope.request ||
    PaletteQueryScope.ci => true,
    _ => false,
  };
}

PaletteQuery parsePaletteQuery(String raw) {
  final colon = raw.indexOf(':');
  if (colon <= 0) return PaletteQuery(text: raw.trim());
  final token = raw.substring(0, colon).trim().toLowerCase();
  final scope = switch (token) {
    'go' => PaletteQueryScope.go,
    'git' => PaletteQueryScope.git,
    'forge' => PaletteQueryScope.forge,
    'app' => PaletteQueryScope.app,
    'branch' => PaletteQueryScope.branch,
    'commit' => PaletteQueryScope.commit,
    'file' => PaletteQueryScope.file,
    'stash' => PaletteQueryScope.stash,
    'worktree' => PaletteQueryScope.worktree,
    'issue' => PaletteQueryScope.issue,
    'request' => PaletteQueryScope.request,
    'ci' => PaletteQueryScope.ci,
    _ => null,
  };
  return scope == null
      ? PaletteQuery(text: raw.trim())
      : PaletteQuery(scope: scope, text: raw.substring(colon + 1).trim());
}

/// Pure, UI-independent metadata for one palette row.
sealed class PaletteEntry {
  final String id;
  final PaletteEntryKind kind;
  final String primaryLabel;
  final String contextLabel;
  final List<String> searchTokens;
  final int recency;
  final List<String> allowedActionIds;
  final PaletteQueryScope category;

  const PaletteEntry({
    required this.id,
    required this.kind,
    required this.primaryLabel,
    this.contextLabel = '',
    this.searchTokens = const [],
    this.recency = 0,
    this.allowedActionIds = const [],
    this.category = PaletteQueryScope.go,
  });

  Iterable<String> get searchable => [
    id,
    primaryLabel,
    contextLabel,
    ...searchTokens,
  ];
}

final class ActionPaletteEntry extends PaletteEntry {
  const ActionPaletteEntry({
    required super.id,
    required super.primaryLabel,
    super.contextLabel,
    super.searchTokens,
    super.recency,
    super.category,
  }) : super(kind: PaletteEntryKind.action);
}

final class PanelPaletteEntry extends PaletteEntry {
  final int panelIndex;
  const PanelPaletteEntry({
    required super.id,
    required super.primaryLabel,
    required this.panelIndex,
  }) : super(kind: PaletteEntryKind.panel, category: PaletteQueryScope.go);
}

final class RepositoryPaletteEntry extends PaletteEntry {
  final String repositoryPath;
  final String connectionId;
  const RepositoryPaletteEntry({
    required super.id,
    required super.primaryLabel,
    required this.repositoryPath,
    required this.connectionId,
    super.contextLabel,
    super.searchTokens,
    super.recency,
    super.allowedActionIds,
  }) : super(kind: PaletteEntryKind.repository, category: PaletteQueryScope.go);
}

final class BranchPaletteEntry extends PaletteEntry {
  final String refName;
  const BranchPaletteEntry({
    required super.id,
    required super.primaryLabel,
    required this.refName,
    bool tag = false,
    super.contextLabel,
    super.searchTokens,
    super.recency,
    super.allowedActionIds,
  }) : super(
         kind: tag ? PaletteEntryKind.tag : PaletteEntryKind.branch,
         category: PaletteQueryScope.git,
       );
}

final class CommitPaletteEntry extends PaletteEntry {
  final String oid;
  const CommitPaletteEntry({
    required super.id,
    required super.primaryLabel,
    required this.oid,
    super.contextLabel,
    super.searchTokens,
    super.recency,
    super.allowedActionIds,
  }) : super(kind: PaletteEntryKind.commit, category: PaletteQueryScope.git);
}

final class FilePaletteEntry extends PaletteEntry {
  final String path;
  const FilePaletteEntry.changed({
    required super.id,
    required super.primaryLabel,
    required this.path,
    super.contextLabel,
    super.searchTokens,
    super.recency,
    super.allowedActionIds,
  }) : super(
         kind: PaletteEntryKind.changedFile,
         category: PaletteQueryScope.git,
       );
  const FilePaletteEntry.repository({
    required super.id,
    required super.primaryLabel,
    required this.path,
    super.contextLabel,
    super.searchTokens,
    super.recency,
    super.allowedActionIds,
  }) : super(
         kind: PaletteEntryKind.repositoryFile,
         category: PaletteQueryScope.go,
       );
}

final class StashPaletteEntry extends PaletteEntry {
  final String oid;
  const StashPaletteEntry({
    required super.id,
    required super.primaryLabel,
    required this.oid,
    super.contextLabel,
    super.searchTokens,
    super.recency,
    super.allowedActionIds,
  }) : super(kind: PaletteEntryKind.stash, category: PaletteQueryScope.git);
}

final class WorktreePaletteEntry extends PaletteEntry {
  final String path;
  const WorktreePaletteEntry({
    required super.id,
    required super.primaryLabel,
    required this.path,
    super.contextLabel,
    super.searchTokens,
    super.recency,
    super.allowedActionIds,
  }) : super(kind: PaletteEntryKind.worktree, category: PaletteQueryScope.go);
}

final class IssuePaletteEntry extends PaletteEntry {
  final String issueId;
  const IssuePaletteEntry({
    required super.id,
    required super.primaryLabel,
    required this.issueId,
    super.contextLabel,
    super.searchTokens,
    super.recency,
    super.allowedActionIds,
  }) : super(kind: PaletteEntryKind.issue, category: PaletteQueryScope.forge);
}

final class ChangeRequestPaletteEntry extends PaletteEntry {
  final String requestId;
  const ChangeRequestPaletteEntry({
    required super.id,
    required super.primaryLabel,
    required this.requestId,
    super.contextLabel,
    super.searchTokens,
    super.recency,
    super.allowedActionIds,
  }) : super(
         kind: PaletteEntryKind.changeRequest,
         category: PaletteQueryScope.forge,
       );
}

final class PipelinePaletteEntry extends PaletteEntry {
  final String pipelineId;
  const PipelinePaletteEntry({
    required super.id,
    required super.primaryLabel,
    required this.pipelineId,
    super.contextLabel,
    super.searchTokens,
    super.recency,
    super.allowedActionIds,
  }) : super(
         kind: PaletteEntryKind.pipeline,
         category: PaletteQueryScope.forge,
       );
}

bool _subsequence(String query, String target) {
  var queryIndex = 0;
  for (var i = 0; i < target.length && queryIndex < query.length; i++) {
    if (target.codeUnitAt(i) == query.codeUnitAt(queryIndex)) queryIndex++;
  }
  return queryIndex == query.length;
}

int? _matchTier(PaletteEntry entry, String text) {
  if (text.isEmpty) return 0;
  final query = text.toLowerCase();
  final values = entry.searchable.map((value) => value.toLowerCase());
  if (values.any((value) => value == query)) return 0;
  if (values.any((value) => value.startsWith(query))) return 1;
  if (values.any((value) => value.contains(query))) return 2;
  if (values.any((value) => _subsequence(query, value))) return 3;
  return null;
}

bool _scopeAllows(PaletteQueryScope scope, PaletteEntry entry) =>
    switch (scope) {
      PaletteQueryScope.all => true,
      PaletteQueryScope.go ||
      PaletteQueryScope.git ||
      PaletteQueryScope.forge ||
      PaletteQueryScope.app => entry.category == scope,
      PaletteQueryScope.branch =>
        entry.kind == PaletteEntryKind.branch ||
            entry.kind == PaletteEntryKind.tag,
      PaletteQueryScope.commit => entry.kind == PaletteEntryKind.commit,
      PaletteQueryScope.file =>
        entry.kind == PaletteEntryKind.changedFile ||
            entry.kind == PaletteEntryKind.repositoryFile,
      PaletteQueryScope.stash => entry.kind == PaletteEntryKind.stash,
      PaletteQueryScope.worktree => entry.kind == PaletteEntryKind.worktree,
      PaletteQueryScope.issue => entry.kind == PaletteEntryKind.issue,
      PaletteQueryScope.request => entry.kind == PaletteEntryKind.changeRequest,
      PaletteQueryScope.ci => entry.kind == PaletteEntryKind.pipeline,
    };

/// Deterministic palette ranking: exact, prefix, current focus, recency, fuzzy.
List<PaletteEntry> rankPaletteEntries(
  Iterable<PaletteEntry> entries,
  PaletteQuery query, {
  String? focusedId,
  int perKindLimit = 50,
  int totalLimit = 100,
}) {
  final scored = <({PaletteEntry entry, int tier, bool focused, int order})>[];
  var order = 0;
  for (final entry in entries) {
    if (!_scopeAllows(query.scope, entry)) continue;
    final tier = _matchTier(entry, query.text);
    if (tier == null) continue;
    scored.add((
      entry: entry,
      tier: tier,
      focused: entry.id == focusedId,
      order: order++,
    ));
  }
  scored.sort((a, b) {
    var result = a.tier.compareTo(b.tier);
    if (result != 0) return result;
    result = (b.focused ? 1 : 0).compareTo(a.focused ? 1 : 0);
    if (result != 0) return result;
    result = b.entry.recency.compareTo(a.entry.recency);
    if (result != 0) return result;
    if (query.text.isEmpty) return a.order.compareTo(b.order);
    result = a.entry.primaryLabel.toLowerCase().compareTo(
      b.entry.primaryLabel.toLowerCase(),
    );
    return result != 0 ? result : a.entry.id.compareTo(b.entry.id);
  });
  final counts = <PaletteEntryKind, int>{};
  final result = <PaletteEntry>[];
  for (final item in scored) {
    final count = counts[item.entry.kind] ?? 0;
    if (count >= perKindLimit) continue;
    counts[item.entry.kind] = count + 1;
    result.add(item.entry);
    if (result.length == totalLimit) break;
  }
  return result;
}
