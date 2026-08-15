import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/app_providers.dart';
import '../tabs/tab_ui_providers.dart';
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

  /// While a restore/reveal is settling, the destination screen still
  /// re-reports its pre-restore selection from post-frame callbacks it
  /// scheduled with build-time values — recording that echo would truncate
  /// the forward stack and undo the Back the user just pressed. Only visits
  /// EQUAL to the pre-restore current are suppressed; any other visit (a
  /// genuinely new selection, the applied restore itself) clears the guard
  /// and records normally.
  WorkspaceFocus? _staleEcho;

  @override
  WorkspaceNavigationState build() => const WorkspaceNavigationState();

  void visit(WorkspaceFocus location) {
    if (location.repositoryPath != session.repositoryPath ||
        location.sessionEpoch != session.sessionEpoch) {
      return;
    }
    if (_staleEcho != null) {
      if (location == _staleEcho && state.current != location) {
        return; // the pre-restore selection re-reporting itself
      }
      _staleEcho = null;
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

  /// Records [location] AND marks it pending, so the owning panel's adapter
  /// selects the object on its next data frame. This is the palette's
  /// "open this entity" path (0009 H3); plain [visit] only records — the
  /// sidebar's `panel:N` visits must never become pending selections.
  void reveal(WorkspaceFocus location) {
    final echo = state.current;
    visit(location);
    if (state.current == location) {
      _staleEcho = echo == location ? null : echo;
      state = state.copyWith(pending: location, clearUnavailable: true);
    }
  }

  WorkspaceFocus? back() => _restore(state.index - 1);
  WorkspaceFocus? forward() => _restore(state.index + 1);

  WorkspaceFocus? _restore(int index) {
    if (index < 0 || index >= state.locations.length) return null;
    final location = state.locations[index];
    _staleEcho = state.current == location ? null : state.current;
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
    // _staleEcho stays: the screen still re-reports its pre-restore
    // selection, and recording that echo would instantly wipe the
    // unavailable notice (visit() builds a fresh state).
    state = state.copyWith(clearPending: true, unavailable: location);
  }
}

final workspaceNavigationProvider =
    NotifierProvider.family<
      WorkspaceNavigationHistory,
      WorkspaceNavigationState,
      WorkspaceSessionKey
    >(WorkspaceNavigationHistory.new);

/// The active session's navigation history, or null when nothing is connected.
///
/// Lifted out of AppShell so the context bar itself can offer Back/Forward on
/// every screen: the history is session state, not one panel's property, and
/// threading two callbacks through six widgets is how five of them ended up
/// without the buttons at all.
WorkspaceNavigationState? watchWorkspaceHistory(WidgetRef ref) {
  final connection = ref.watch(connectionProvider);
  final repoPath = connection.repoPath;
  if (repoPath == null || connection.sessionEpoch <= 0) return null;
  return ref.watch(
    workspaceNavigationProvider(
      WorkspaceSessionKey(repoPath, connection.sessionEpoch),
    ),
  );
}

/// The active session's pending location for [panelIndex], WITHOUT consuming
/// it. Screens watch this and only take ([takeWorkspaceLocation]) once their
/// data can resolve the identity — taking earlier would consume-and-drop a
/// restore that raced a still-loading provider (0009 H3).
WorkspaceFocus? pendingWorkspaceLocation(WidgetRef ref, int panelIndex) {
  final connection = ref.watch(connectionProvider);
  final repoPath = connection.repoPath;
  if (repoPath == null || connection.sessionEpoch <= 0) return null;
  final pending = ref.watch(
    workspaceNavigationProvider(
      WorkspaceSessionKey(repoPath, connection.sessionEpoch),
    ).select((s) => s.pending),
  );
  if (pending == null || pending.panelIndex != panelIndex) return null;
  // Sidebar flips record `panel:N` repository identities — never a selection.
  if (pending.kind == WorkspaceFocusKind.repository) return null;
  return pending;
}

/// Consumes [panelIndex]'s pending location (see [pendingWorkspaceLocation]).
WorkspaceFocus? takeWorkspaceLocation(WidgetRef ref, int panelIndex) {
  final connection = ref.read(connectionProvider);
  final repoPath = connection.repoPath;
  if (repoPath == null || connection.sessionEpoch <= 0) return null;
  return ref
      .read(
        workspaceNavigationProvider(
          WorkspaceSessionKey(repoPath, connection.sessionEpoch),
        ).notifier,
      )
      .takePendingForPanel(panelIndex);
}

/// Reports a restored [location] whose identity no longer exists — Back
/// stays deterministic and the chrome can say so.
void markWorkspaceLocationUnavailable(WidgetRef ref, WorkspaceFocus location) {
  final connection = ref.read(connectionProvider);
  final repoPath = connection.repoPath;
  if (repoPath == null || connection.sessionEpoch <= 0) return;
  ref
      .read(
        workspaceNavigationProvider(
          WorkspaceSessionKey(repoPath, connection.sessionEpoch),
        ).notifier,
      )
      .markUnavailable(location);
}

/// Steps the active session's history and switches to the panel it lands on.
void restoreWorkspaceLocation(WidgetRef ref, {required bool forward}) {
  final connection = ref.read(connectionProvider);
  final repoPath = connection.repoPath;
  if (repoPath == null || connection.sessionEpoch <= 0) return;
  final history = ref.read(
    workspaceNavigationProvider(
      WorkspaceSessionKey(repoPath, connection.sessionEpoch),
    ).notifier,
  );
  final location = forward ? history.forward() : history.back();
  if (location == null) return;
  ref.read(pageIndexProvider.notifier).select(location.panelIndex);
  ref.read(visitedPagesProvider.notifier).visit(location.panelIndex);
}
