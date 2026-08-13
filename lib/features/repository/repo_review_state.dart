import 'package:flutter/foundation.dart';

import 'repo_change_model.dart';

@immutable
class ReviewItemId {
  final RepoChangeSection section;
  final String path;
  final String worktreeRevision;

  const ReviewItemId({
    required this.section,
    required this.path,
    required this.worktreeRevision,
  });

  String get pathIdentity => '${section.name}:$path';

  @override
  bool operator ==(Object other) =>
      other is ReviewItemId &&
      other.section == section &&
      other.path == path &&
      other.worktreeRevision == worktreeRevision;

  @override
  int get hashCode => Object.hash(section, path, worktreeRevision);
}

@immutable
class RepoReviewState {
  final List<ReviewItemId> items;
  final int activeIndex;
  final Set<ReviewItemId> reviewed;
  final Set<ReviewItemId> collapsed;

  const RepoReviewState({
    this.items = const [],
    this.activeIndex = 0,
    this.reviewed = const {},
    this.collapsed = const {},
  });

  ReviewItemId? get active => items.isEmpty ? null : items[activeIndex];

  RepoReviewState replaceItems(List<ReviewItemId> next) {
    final nextSet = next.toSet();
    final previousActive = active;
    final nextIndex = previousActive == null
        ? 0
        : next.indexWhere((item) => item == previousActive);
    return RepoReviewState(
      items: List.unmodifiable(next),
      activeIndex: next.isEmpty ? 0 : (nextIndex < 0 ? 0 : nextIndex),
      reviewed: reviewed.intersection(nextSet),
      collapsed: collapsed.intersection(nextSet),
    );
  }

  RepoReviewState select(int index) => items.isEmpty
      ? this
      : copyWith(activeIndex: index.clamp(0, items.length - 1));

  RepoReviewState move(int delta) => select(activeIndex + delta);

  RepoReviewState toggleReviewed(ReviewItemId item) {
    final next = {...reviewed};
    next.contains(item) ? next.remove(item) : next.add(item);
    return copyWith(reviewed: next);
  }

  RepoReviewState toggleCollapsed(ReviewItemId item) {
    final next = {...collapsed};
    next.contains(item) ? next.remove(item) : next.add(item);
    return copyWith(collapsed: next);
  }

  RepoReviewState copyWith({
    List<ReviewItemId>? items,
    int? activeIndex,
    Set<ReviewItemId>? reviewed,
    Set<ReviewItemId>? collapsed,
  }) => RepoReviewState(
    items: items ?? this.items,
    activeIndex: activeIndex ?? this.activeIndex,
    reviewed: reviewed ?? this.reviewed,
    collapsed: collapsed ?? this.collapsed,
  );
}

class RepoReviewController extends ValueNotifier<RepoReviewState> {
  RepoReviewController() : super(const RepoReviewState());

  void open(List<ReviewItemId> items) => value = value.replaceItems(items);
  void move(int delta) => value = value.move(delta);
  void select(int index) => value = value.select(index);
  void toggleReviewed(ReviewItemId item) => value = value.toggleReviewed(item);
  void toggleCollapsed(ReviewItemId item) =>
      value = value.toggleCollapsed(item);
  void clear() => value = const RepoReviewState();
}

List<ReviewItemId> reviewItemsFromRows(
  List<RepoChangeRow> rows, {
  required Set<String> paths,
  RepoChangeSection? section,
}) => [
  for (final row in rows)
    if (row is RepoChangeFileRow &&
        paths.contains(row.file.path) &&
        (section == null || row.section == section))
      ReviewItemId(
        section: row.section,
        path: row.file.path,
        worktreeRevision:
            '${row.file.statusX}${row.file.statusY}:${row.file.oldPath ?? ''}',
      ),
];
