import 'package:flutter/foundation.dart';

import '../../core/utils/git_porcelain_parser.dart';

enum RepoChangeSection { conflict, staged, unstaged, untracked }

sealed class RepoChangeRow {
  const RepoChangeRow();
}

class RepoChangeHeaderRow extends RepoChangeRow {
  final String title;
  final int count;
  final bool conflict;
  final String? directory;

  const RepoChangeHeaderRow(
    this.title,
    this.count, {
    this.conflict = false,
    this.directory,
  });
}

class RepoChangeFileRow extends RepoChangeRow {
  final GitFileStatus file;
  final bool staged;
  final bool discardable;
  final bool conflict;

  const RepoChangeFileRow(
    this.file, {
    required this.staged,
    this.discardable = false,
    this.conflict = false,
  });

  RepoChangeSection get section => conflict
      ? RepoChangeSection.conflict
      : staged
      ? RepoChangeSection.staged
      : file.isUntracked
      ? RepoChangeSection.untracked
      : RepoChangeSection.unstaged;

  String get identity => '${section.name}:${file.path}';
}

List<RepoChangeRow> deriveRepoChangeRows(GitStatus status) {
  final rows = <RepoChangeRow>[];
  void addSection(
    String title,
    List<GitFileStatus> files, {
    required bool staged,
    bool discardable = false,
    bool conflict = false,
  }) {
    if (files.isEmpty) return;
    rows.add(RepoChangeHeaderRow(title, files.length, conflict: conflict));
    for (final file in files) {
      rows.add(
        RepoChangeFileRow(
          file,
          staged: staged,
          discardable: discardable,
          conflict: conflict,
        ),
      );
    }
  }

  addSection('Conflicts', status.conflicted, staged: false, conflict: true);
  addSection('Staged', status.staged, staged: true);
  addSection('Changes', status.unstaged, staged: false, discardable: true);
  addSection('Untracked', status.untracked, staged: false, discardable: true);
  return List.unmodifiable(rows);
}

@immutable
class RepoChangeSelection {
  final RepoChangeSection? section;
  final Set<String> paths;
  final String? anchor;

  /// True when this selection came from the FILE TREE rather than the Changes
  /// list.
  ///
  /// The tree can select a clean file — one that appears in no status section
  /// at all — which is indistinguishable, after the fact, from a Changes-list
  /// entry whose file has just left the working tree. The first must survive
  /// [reconcile] (or the tree highlight flickers away on every `git status`
  /// tick); the second must be dropped. Only the origin separates them.
  final bool fromTree;

  const RepoChangeSelection({
    this.section,
    this.paths = const {},
    this.anchor,
    this.fromTree = false,
  });

  const RepoChangeSelection.empty()
    : section = null,
      paths = const {},
      anchor = null,
      fromTree = false;

  bool get isEmpty => paths.isEmpty;
  int get count => paths.length;

  bool contains(String path, RepoChangeSection candidate) =>
      section == candidate && paths.contains(path);

  RepoChangeSelection select(
    List<RepoChangeRow> rows,
    String path,
    RepoChangeSection candidate, {
    bool toggle = false,
    bool range = false,
  }) {
    if (toggle && section == candidate) {
      final next = {...paths};
      next.contains(path) ? next.remove(path) : next.add(path);
      return next.isEmpty
          ? const RepoChangeSelection.empty()
          : RepoChangeSelection(section: candidate, paths: next, anchor: path);
    }
    if (range && section == candidate && anchor != null) {
      return RepoChangeSelection(
        section: candidate,
        paths: rangeBetween(rows, candidate, anchor!, path),
        anchor: anchor,
      );
    }
    return RepoChangeSelection(section: candidate, paths: {path}, anchor: path);
  }

  RepoChangeSelection remove(Iterable<String> removed) {
    final next = {...paths}..removeAll(removed);
    if (next.isEmpty) return const RepoChangeSelection.empty();
    return RepoChangeSelection(
      section: section,
      paths: next,
      anchor: next.contains(anchor) ? anchor : next.first,
    );
  }

  RepoChangeSelection rehome(
    Iterable<String> moved,
    RepoChangeSection destination,
  ) {
    final retained = moved.toSet().intersection(paths);
    if (retained.isEmpty) return this;
    return RepoChangeSelection(
      section: destination,
      paths: retained,
      anchor: retained.contains(anchor) ? anchor : retained.first,
    );
  }

  RepoChangeSelection reconcile(GitStatus status) {
    final currentSection = section;
    if (currentSection == null || paths.isEmpty) return this;
    // A tree-origin selection is not a Changes-list entry, so reconciling it
    // against the Changes list is a category error — a clean file legitimately
    // appears in no section.
    if (fromTree) return this;
    final inSection = pathsInRepoChangeSection(status, currentSection);
    final retained = paths.intersection(inSection);
    if (retained.length == paths.length) return this;
    if (retained.isNotEmpty) {
      return RepoChangeSelection(
        section: currentSection,
        paths: retained,
        anchor: retained.contains(anchor) ? anchor : retained.first,
      );
    }

    RepoChangeSection? destination;
    final moved = <String>{};
    for (final path in paths) {
      final next = repoChangeSectionOfPath(
        status,
        path,
        preferred: currentSection,
      );
      if (next == null) continue;
      if (destination != null && destination != next) {
        return const RepoChangeSelection.empty();
      }
      destination = next;
      moved.add(path);
    }
    if (destination == null || moved.length != paths.length) {
      return const RepoChangeSelection.empty();
    }
    return RepoChangeSelection(
      section: destination,
      paths: moved,
      anchor: moved.contains(anchor) ? anchor : moved.first,
    );
  }

  RepoChangeSelection copyWith({
    RepoChangeSection? section,
    Set<String>? paths,
    String? anchor,
    bool clearSection = false,
    bool clearAnchor = false,
    bool? fromTree,
  }) => RepoChangeSelection(
    section: clearSection ? null : (section ?? this.section),
    paths: paths ?? this.paths,
    anchor: clearAnchor ? null : (anchor ?? this.anchor),
    fromTree: fromTree ?? this.fromTree,
  );
}

class RepoChangeSelectionController extends ValueNotifier<RepoChangeSelection> {
  RepoChangeSelectionController([
    super.value = const RepoChangeSelection.empty(),
  ]);

  void clear() => value = const RepoChangeSelection.empty();

  void select(
    List<RepoChangeRow> rows,
    String path,
    RepoChangeSection section, {
    bool toggle = false,
    bool range = false,
  }) {
    value = value.select(rows, path, section, toggle: toggle, range: range);
  }

  void reconcile(GitStatus status) => value = value.reconcile(status);
}

Set<String> rangeBetween(
  List<RepoChangeRow> rows,
  RepoChangeSection section,
  String anchor,
  String target,
) {
  final paths = [
    for (final row in rows)
      if (row is RepoChangeFileRow && row.section == section) row.file.path,
  ];
  final first = paths.indexOf(anchor);
  final last = paths.indexOf(target);
  if (first == -1 || last == -1) return {target};
  final low = first < last ? first : last;
  final high = first < last ? last : first;
  return paths.sublist(low, high + 1).toSet();
}

Set<String> pathsInRepoChangeSection(
  GitStatus status,
  RepoChangeSection section,
) => switch (section) {
  RepoChangeSection.conflict => {
    for (final file in status.conflicted) file.path,
  },
  RepoChangeSection.staged => {for (final file in status.staged) file.path},
  RepoChangeSection.unstaged => {for (final file in status.unstaged) file.path},
  RepoChangeSection.untracked => {
    for (final file in status.untracked) file.path,
  },
};

RepoChangeSection? repoChangeSectionOfPath(
  GitStatus status,
  String path, {
  RepoChangeSection? preferred,
}) {
  if (status.conflicted.any((file) => file.path == path)) {
    return RepoChangeSection.conflict;
  }
  final staged = status.staged.any((file) => file.path == path);
  final unstaged = status.unstaged.any((file) => file.path == path);
  if (staged && unstaged) {
    return preferred == RepoChangeSection.staged
        ? RepoChangeSection.staged
        : RepoChangeSection.unstaged;
  }
  if (staged) return RepoChangeSection.staged;
  if (unstaged) return RepoChangeSection.unstaged;
  if (status.untracked.any((file) => file.path == path)) {
    return RepoChangeSection.untracked;
  }
  return null;
}
