import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/app_providers.dart';
import '../common/context_menu.dart';
import 'drag_item.dart';
import 'drag_state.dart';
import 'drop_registry.dart';

/// Wraps a target as a [DragItem] drop zone. It accepts a payload only when the
/// registry has an action for (payload, [id]); on drop it dispatches via
/// [runDrop] (running a single safe action, or presenting a verb menu). The
/// [builder] is handed `isHovering` so the target can render its own hover
/// affordance (the nav rail combines it with the drag-eligible highlight).
///
/// [selectPage] and [refresh] are the shell's post-drop navigation and
/// repo-refresh hooks, threaded into the [DropContext].
class DropZone extends ConsumerStatefulWidget {
  final DropZoneId id;
  final Widget Function(BuildContext context, bool isHovering) builder;
  final void Function(int pageIndex) selectPage;
  final VoidCallback refresh;

  const DropZone({
    super.key,
    required this.id,
    required this.builder,
    required this.selectPage,
    required this.refresh,
  });

  @override
  ConsumerState<DropZone> createState() => _DropZoneState();
}

class _DropZoneState extends ConsumerState<DropZone> {
  final ContextMenuOverlay _menu = ContextMenuOverlay();

  @override
  void dispose() {
    _menu.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DragTarget<DragItem>(
      onWillAcceptWithDetails: (details) => canDrop(details.data, widget.id),
      onAcceptWithDetails: (details) {
        // ESC cancelled this drag (the gesture itself can't be aborted, only
        // its release) — a cancelled drop is a no-op everywhere.
        if (ref.read(dragStateProvider) == null) return;
        final repoPath = ref.read(connectionProvider).repoPath;
        if (repoPath == null) return;
        runDrop(
          details.data,
          widget.id,
          DropContext(
            ref: ref,
            context: context,
            repoPath: repoPath,
            selectPage: widget.selectPage,
            refresh: widget.refresh,
            menu: _menu,
          ),
          details.offset,
        );
      },
      builder: (context, candidate, rejected) =>
          widget.builder(context, candidate.isNotEmpty),
    );
  }
}
