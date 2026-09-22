import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'workspace_focus.dart';
import 'workspace_navigation.dart';

/// Records a panel's current location in the session's navigation history:
/// once per change, and only while the panel is the active page.
///
/// Panels call [recordWorkspaceLocation] from `build` with the location their
/// landed data resolves to, because that is where the comparison base, range
/// end or path filter a location carries is known. The call is idempotent — an
/// unchanged location schedules nothing — so a rebuild is not a visit, and two
/// mounted panels holding selections can no longer alternate entries one
/// frame at a time (0065-MADR).
mixin WorkspaceLocationRecorder<T extends ConsumerStatefulWidget>
    on ConsumerState<T> {
  WorkspaceFocus? _recordedLocation;

  /// [location] is null when nothing is selected; [active] is the panel's
  /// `widget.isActive`. Hidden panels record nothing and forget what they last
  /// recorded, so becoming the active page with a selection records it once.
  /// A deselection also forgets, so re-selecting the same object records again.
  void recordWorkspaceLocation(
    WorkspaceFocus? location, {
    required bool active,
  }) {
    if (!active || location == null) {
      _recordedLocation = null;
      return;
    }
    if (location == _recordedLocation) return;
    // Set before scheduling: two builds in one frame must not double-record.
    _recordedLocation = location;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref
          .read(
            workspaceNavigationProvider(
              WorkspaceSessionKey(
                location.repositoryPath,
                location.sessionEpoch,
              ),
            ).notifier,
          )
          .visit(location);
    });
  }
}
