import 'package:flutter/foundation.dart';

export '../../core/settings/repository_workspace_prefs.dart'
    show WorkspacePreset;

enum WorkspacePaneRole {
  repositoryContext,
  navigator,
  canvas,
  inspector,
  taskDock,
}

enum WorkspaceSizeClass {
  compact,
  standard,
  wide;

  static const double standardMinWidth = 720;
  static const double wideMinWidth = 1200;

  static WorkspaceSizeClass fromWidth(double contentWidth) {
    assert(contentWidth.isFinite && contentWidth >= 0);
    if (contentWidth < standardMinWidth) return compact;
    if (contentWidth < wideMinWidth) return standard;
    return wide;
  }
}

enum WorkspaceSelectionKind {
  changedPath,
  repositoryPath,
  commit,
  branch,
  tag,
  stash,
  worktree,
  forgeEntity,
}

@immutable
class WorkspaceSelection {
  final WorkspaceSelectionKind kind;
  final Set<String> ids;
  final String? anchorId;

  WorkspaceSelection({required this.kind, this.ids = const {}, this.anchorId})
    : assert(anchorId == null || ids.contains(anchorId));

  int get count => ids.length;
  bool get isEmpty => ids.isEmpty;
  bool contains(String id) => ids.contains(id);
}

enum WorkspaceAsyncPhase {
  loading,
  data,
  empty,
  partialError,
  stale,
  unavailable,
}

@immutable
class WorkspaceAsyncState<T> {
  final WorkspaceAsyncPhase phase;
  final T? data;
  final Object? error;
  final String? message;

  const WorkspaceAsyncState.loading()
    : phase = WorkspaceAsyncPhase.loading,
      data = null,
      error = null,
      message = null;

  const WorkspaceAsyncState.data(T this.data)
    : phase = WorkspaceAsyncPhase.data,
      error = null,
      message = null;

  const WorkspaceAsyncState.empty([this.message])
    : phase = WorkspaceAsyncPhase.empty,
      data = null,
      error = null;

  const WorkspaceAsyncState.partialError(T this.data, Object this.error)
    : phase = WorkspaceAsyncPhase.partialError,
      message = null;

  const WorkspaceAsyncState.stale(T this.data, [this.message])
    : phase = WorkspaceAsyncPhase.stale,
      error = null;

  const WorkspaceAsyncState.unavailable([this.message])
    : phase = WorkspaceAsyncPhase.unavailable,
      data = null,
      error = null;

  bool get hasData => data != null;
  bool get hasError => error != null;
  bool get isStale => phase == WorkspaceAsyncPhase.stale;
}

enum WorkspaceActionIntent {
  primary,
  secondary,
  navigation,
  disclosure,
  destructive,
}

@immutable
class WorkspaceAction {
  final String id;
  final String label;
  final WorkspaceActionIntent intent;
  final String? disabledReason;
  final bool destructive;
  final String? shortcutHint;
  final VoidCallback? onInvoke;

  const WorkspaceAction({
    required this.id,
    required this.label,
    required this.intent,
    this.disabledReason,
    this.destructive = false,
    this.shortcutHint,
    required this.onInvoke,
  }) : assert(id != ''),
       assert(label != ''),
       assert(onInvoke != null || disabledReason != null),
       assert(
         intent != WorkspaceActionIntent.destructive || destructive,
         'A destructive intent must opt into destructive presentation.',
       );

  const WorkspaceAction.disabled({
    required this.id,
    required this.label,
    required this.intent,
    required String reason,
    this.destructive = false,
    this.shortcutHint,
  }) : disabledReason = reason,
       onInvoke = null,
       assert(id != ''),
       assert(label != ''),
       assert(reason != ''),
       assert(
         intent != WorkspaceActionIntent.destructive || destructive,
         'A destructive intent must opt into destructive presentation.',
       );

  bool get enabled => onInvoke != null;

  void invoke() => onInvoke?.call();
}
