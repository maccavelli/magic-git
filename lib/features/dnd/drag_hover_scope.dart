import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'drag_state.dart';

/// Gives one drop target its own [DragHoverReport] and releases it when the
/// target leaves the tree (MADR 0064 F2).
///
/// Flutter never calls `onLeave` on a drop target that is unmounted mid-drag
/// (a list refresh rebuilding History rows, a page unmounting), so a target
/// that held the hover would otherwise leave the drag image as a compact chip
/// over empty space until the release. The report is owned by this element:
/// its disposal clears the hover only if this target still holds it, so
/// removing one target never takes the hover from another.
///
/// Wrap each drop target in one, and report through the handle the builder
/// receives: `hover.setOverTarget(true)` from `onMove` (guarded by the
/// target's acceptance test), `hover.setOverTarget(false)` from `onLeave` and
/// on accept.
class DragHoverScope extends ConsumerStatefulWidget {
  final Widget Function(BuildContext context, DragHoverReport hover) builder;

  const DragHoverScope({super.key, required this.builder});

  @override
  ConsumerState<DragHoverScope> createState() => _DragHoverScopeState();
}

class _DragHoverScopeState extends ConsumerState<DragHoverScope> {
  late final DragHoverReport _hover;

  @override
  void initState() {
    super.initState();
    // Bound to the notifier, not `ref`: the notifier stays valid for the
    // tab's lifetime, and dispose must not touch `ref`.
    _hover = DragHoverReport(ref.read(dragStateProvider.notifier));
  }

  @override
  void dispose() {
    _hover.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _hover);
}
