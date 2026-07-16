import 'dart:math' as math;

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/settings/app_settings.dart';
import '../../core/settings/pane_layout.dart';

/// A master/detail split whose divider the user can drag, with the chosen
/// width persisted per [PaneId] in app settings (so it survives restarts and
/// syncs between the main window and pop-outs, like every other setting).
///
/// Replaces the previously fixed splits' whole
/// `Row[SizedBox(width: W), 1px separator, Expanded(detail)]` — the widget
/// must own the Row because drag clamping is layout-aware (the master may
/// never squeeze the detail below [detailFloor]), and only the Row's owner
/// can know the available width: a non-flex Row child is laid out under
/// unbounded constraints, so a LayoutBuilder *inside* the Row learns nothing.
///
/// Interaction contract:
///  * Dragging updates local State only; the width is persisted exactly once,
///    on drag end — never per frame.
///  * When the window is too narrow for the stored width, the pane renders
///    clamped but the stored value is untouched — only a user gesture writes.
///  * Double-click on the divider resets to the pane's spec default.
///
/// Visuals are identical to the fixed splits this replaces: the same 1px
/// [MacosColors.separatorColor] line; the 9px grab strip is a hit-test
/// overlay with no layout footprint.
class ResizableMasterDetail extends ConsumerStatefulWidget {
  final PaneId paneId;
  final Widget master;
  final Widget detail;

  /// Width the detail pane is guaranteed before the master's drag ceiling
  /// gives way. Tune per site (a diff pane needs more than a log pane).
  final double detailFloor;

  const ResizableMasterDetail({
    super.key,
    required this.paneId,
    required this.master,
    required this.detail,
    this.detailFloor = 280,
  });

  @override
  ConsumerState<ResizableMasterDetail> createState() =>
      _ResizableMasterDetailState();
}

class _ResizableMasterDetailState extends ConsumerState<ResizableMasterDetail> {
  /// The in-flight drag width; null when not dragging. The persisted setting
  /// is the source of truth between drags — deliberately read in build (never
  /// cached in initState) so a remount mid-session (e.g. stash's split lives
  /// inside an AsyncValue.when branch) re-applies the stored width.
  double? _dragWidth;

  /// The clamp bounds of the current layout, stashed by build for the drag
  /// callbacks (clamping in the update keeps the divider under the cursor —
  /// clamping only at render would let dead travel accumulate on reversal).
  var _bounds = (min: 0.0, max: double.infinity);

  void _commit() {
    final width = _dragWidth;
    if (width == null) return;
    // Persist BEFORE dropping the local override: the notifier assigns its
    // state synchronously (ahead of its await on prefs), so by the time the
    // override is gone the watched stored value already equals it — no
    // one-frame snap-back.
    ref.read(appSettingsProvider.notifier).setPaneWidth(widget.paneId, width);
    setState(() => _dragWidth = null);
  }

  /// A cancelled drag reverts to the stored width — it must NOT commit:
  /// committing would persist the *rendered* width, and when that width is
  /// display-clamped (window narrower than the stored value) an aborted
  /// gesture would silently overwrite the user's real choice.
  void _discard() {
    if (_dragWidth != null) setState(() => _dragWidth = null);
  }

  @override
  Widget build(BuildContext context) {
    final spec = paneSpecs[widget.paneId]!;
    final stored = ref.watch(
      appSettingsProvider.select((s) => s.paneWidth(widget.paneId)),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        // Ceiling: the spec's, AND leave the detail its floor. The max()
        // pre-guard is mandatory — Dart's clamp THROWS when max < min, and
        // available − detailFloor drops below spec.min at the 640px window
        // minimum with the sidebar open.
        final ceiling = math.max(
          spec.min,
          math.min(spec.max, constraints.maxWidth - widget.detailFloor - 1),
        );
        _bounds = (min: spec.min, max: ceiling);
        var effective =
            ((_dragWidth ?? stored).clamp(spec.min, ceiling)).toDouble();
        // Degenerate layouts (narrower than spec.min + detailFloor): the
        // master may still never exceed the row itself.
        effective = math.min(effective, math.max(0, constraints.maxWidth - 1));
        return Stack(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: effective, child: widget.master),
                Container(width: 1, color: MacosColors.separatorColor),
                Expanded(child: widget.detail),
              ],
            ),
            // The grab strip: 9px centered on the 1px line. Opaque (like
            // file_view's handle and native NSSplitView dividers) — a
            // translucent strip with onDoubleTap would defer every nearby
            // single click ~300ms for double-tap disambiguation.
            Positioned(
              left: effective - 4,
              top: 0,
              bottom: 0,
              width: 9,
              child: MouseRegion(
                cursor: SystemMouseCursors.resizeLeftRight,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  // .down, not the default .start: the accepting move's delta
                  // then flows into the first onHorizontalDragUpdate instead
                  // of being consumed as slop — the divider tracks the cursor
                  // from the first pixel, with no dead zone.
                  dragStartBehavior: DragStartBehavior.down,
                  onHorizontalDragStart: (_) =>
                      // Anchor on what is RENDERED: a display-clamped stored
                      // width must drag from its on-screen position, not jump
                      // to the stored one.
                      setState(() => _dragWidth = effective),
                  onHorizontalDragUpdate: (d) => setState(() {
                    _dragWidth = ((_dragWidth ?? effective) + d.delta.dx)
                        .clamp(_bounds.min, _bounds.max)
                        .toDouble();
                  }),
                  onHorizontalDragEnd: (_) => _commit(),
                  onHorizontalDragCancel: _discard,
                  onDoubleTap: () => ref
                      .read(appSettingsProvider.notifier)
                      .setPaneWidth(widget.paneId, spec.defaultWidth),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
