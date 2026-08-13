import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'workspace_focus.dart';

/// Destination pages implement this seam when they can resolve a semantic
/// location after their lazy provider data lands.
abstract interface class WorkspaceLocationAdapter {
  int get panelIndex;

  /// Returns false when the stable identity no longer exists. Callers retain
  /// the unavailable location so Back remains deterministic.
  Future<bool> applyWorkspaceLocation(WorkspaceFocus location);
}

class WorkspaceNavigationState {
  final List<WorkspaceFocus> locations;
  final int index;
  final WorkspaceFocus? pending;
  final WorkspaceFocus? unavailable;

  const WorkspaceNavigationState({
    this.locations = const [],
    this.index = -1,
    this.pending,
    this.unavailable,
  });

  WorkspaceFocus? get current =>
      index >= 0 && index < locations.length ? locations[index] : null;
  bool get canBack => index > 0;
  bool get canForward => index >= 0 && index < locations.length - 1;

  WorkspaceNavigationState copyWith({
    List<WorkspaceFocus>? locations,
    int? index,
    WorkspaceFocus? pending,
    bool clearPending = false,
    WorkspaceFocus? unavailable,
    bool clearUnavailable = false,
  }) => WorkspaceNavigationState(
    locations: locations ?? this.locations,
    index: index ?? this.index,
    pending: clearPending ? null : pending ?? this.pending,
    unavailable: clearUnavailable ? null : unavailable ?? this.unavailable,
  );
}

class WorkspaceNavigationHistory extends Notifier<WorkspaceNavigationState> {
  WorkspaceNavigationHistory(this.session);
  final WorkspaceSessionKey session;
  static const int capacity = 50;

  @override
  WorkspaceNavigationState build() => const WorkspaceNavigationState();

  void visit(WorkspaceFocus location) {
    if (location.repositoryPath != session.repositoryPath ||
        location.sessionEpoch != session.sessionEpoch) {
      return;
    }
    if (state.current == location) return;
    var entries = state.index < state.locations.length - 1
        ? state.locations.sublist(0, state.index + 1)
        : [...state.locations];
    entries = [...entries, location];
    if (entries.length > capacity) {
      entries = entries.sublist(entries.length - capacity);
    }
    state = WorkspaceNavigationState(
      locations: entries,
      index: entries.length - 1,
    );
  }

  WorkspaceFocus? back() => _restore(state.index - 1);
  WorkspaceFocus? forward() => _restore(state.index + 1);

  WorkspaceFocus? _restore(int index) {
    if (index < 0 || index >= state.locations.length) return null;
    final location = state.locations[index];
    state = state.copyWith(
      index: index,
      pending: location,
      clearUnavailable: true,
    );
    return location;
  }

  WorkspaceFocus? takePendingForPanel(int panelIndex) {
    final pending = state.pending;
    if (pending == null || pending.panelIndex != panelIndex) return null;
    state = state.copyWith(clearPending: true);
    return pending;
  }

  void resolved(WorkspaceFocus location) {
    if (state.pending == location) {
      state = state.copyWith(clearPending: true, clearUnavailable: true);
    }
  }

  void markUnavailable(WorkspaceFocus location) {
    state = state.copyWith(clearPending: true, unavailable: location);
  }
}

final workspaceNavigationProvider =
    NotifierProvider.family<
      WorkspaceNavigationHistory,
      WorkspaceNavigationState,
      WorkspaceSessionKey
    >(WorkspaceNavigationHistory.new);
