import '../../core/settings/repository_workspace_prefs.dart';
import 'repo_change_model.dart';

class RepoChangeFilter {
  final String query;
  final Set<RepoChangeSection> statuses;
  final String? pathScope;
  final RepositoryChangeGrouping grouping;
  final bool includeReviewed;
  final bool caseSensitive;

  const RepoChangeFilter({
    this.query = '',
    this.statuses = const {},
    this.pathScope,
    this.grouping = RepositoryChangeGrouping.status,
    this.includeReviewed = true,
    this.caseSensitive = false,
  });

  bool get active =>
      query.trim().isNotEmpty ||
      statuses.isNotEmpty ||
      (pathScope?.isNotEmpty ?? false) ||
      !includeReviewed;

  RepoChangeFilter copyWith({
    String? query,
    Set<RepoChangeSection>? statuses,
    String? pathScope,
    RepositoryChangeGrouping? grouping,
    bool? includeReviewed,
    bool? caseSensitive,
    bool clearPathScope = false,
  }) => RepoChangeFilter(
    query: query ?? this.query,
    statuses: statuses ?? this.statuses,
    pathScope: clearPathScope ? null : (pathScope ?? this.pathScope),
    grouping: grouping ?? this.grouping,
    includeReviewed: includeReviewed ?? this.includeReviewed,
    caseSensitive: caseSensitive ?? this.caseSensitive,
  );
}

class RepoChangeFilterResult {
  final List<RepoChangeRow> rows;
  final int totalFiles;
  final int visibleFiles;

  const RepoChangeFilterResult({
    required this.rows,
    required this.totalFiles,
    required this.visibleFiles,
  });

  int get hiddenFiles => totalFiles - visibleFiles;
}

RepoChangeFilterResult filterRepoChangeRows(
  List<RepoChangeRow> canonical,
  RepoChangeFilter filter, {
  Set<String> reviewedPaths = const {},
}) {
  final allFiles = canonical.whereType<RepoChangeFileRow>().toList();
  final query = filter.caseSensitive
      ? filter.query.trim()
      : filter.query.trim().toLowerCase();
  final scope = filter.caseSensitive
      ? filter.pathScope
      : filter.pathScope?.toLowerCase();
  final visible = allFiles.where((row) {
    if (filter.statuses.isNotEmpty && !filter.statuses.contains(row.section)) {
      return false;
    }
    final path = filter.caseSensitive
        ? row.file.path
        : row.file.path.toLowerCase();
    if (query.isNotEmpty && !path.contains(query)) return false;
    if (scope != null && scope.isNotEmpty && !path.startsWith(scope)) {
      return false;
    }
    if (!filter.includeReviewed && reviewedPaths.contains(row.identity)) {
      return false;
    }
    return true;
  }).toList();

  final rows = filter.grouping == RepositoryChangeGrouping.directory
      ? _groupByDirectory(visible)
      : _groupByStatus(visible);
  return RepoChangeFilterResult(
    rows: List.unmodifiable(rows),
    totalFiles: allFiles.length,
    visibleFiles: visible.length,
  );
}

List<RepoChangeRow> _groupByStatus(List<RepoChangeFileRow> files) {
  final rows = <RepoChangeRow>[];
  const labels = <RepoChangeSection, String>{
    RepoChangeSection.conflict: 'Conflicts',
    RepoChangeSection.staged: 'Staged',
    RepoChangeSection.unstaged: 'Changes',
    RepoChangeSection.untracked: 'Untracked',
  };
  for (final section in RepoChangeSection.values) {
    final sectionFiles = files.where((row) => row.section == section).toList();
    if (sectionFiles.isEmpty) continue;
    rows
      ..add(
        RepoChangeHeaderRow(
          labels[section]!,
          sectionFiles.length,
          conflict: section == RepoChangeSection.conflict,
        ),
      )
      ..addAll(sectionFiles);
  }
  return rows;
}

List<RepoChangeRow> _groupByDirectory(List<RepoChangeFileRow> files) {
  final groups = <String, List<RepoChangeFileRow>>{};
  for (final row in files) {
    final slash = row.file.path.lastIndexOf('/');
    final directory = slash < 0
        ? 'Repository root'
        : row.file.path.substring(0, slash);
    groups.putIfAbsent(directory, () => []).add(row);
  }
  final names = groups.keys.toList()..sort();
  return [
    for (final name in names) ...[
      RepoChangeHeaderRow(name, groups[name]!.length, directory: name),
      ..._sortedByPath(groups[name]!),
    ],
  ];
}

List<RepoChangeFileRow> _sortedByPath(List<RepoChangeFileRow> rows) =>
    rows.toList()..sort((a, b) => a.file.path.compareTo(b.file.path));
