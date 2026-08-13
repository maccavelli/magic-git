import 'dart:math' as math;

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/settings/app_settings.dart';
import '../../core/settings/pane_layout.dart';

/// Reusable, accessible split primitive. It owns only interaction-local state;
/// its caller owns and persists [extent].
class ResizablePanePair extends StatefulWidget {
  final Axis axis;
  final Widget leading;
  final Widget trailing;
  final double extent;
  final double minExtent;
  final double maxExtent;
  final double trailingFloor;
  final double defaultExtent;
  final bool collapsed;
  final String semanticLabel;
  final ValueChanged<double> onCommit;

  const ResizablePanePair({
    super.key,
    this.axis = Axis.horizontal,
    required this.leading,
    required this.trailing,
    required this.extent,
    required this.minExtent,
    required this.maxExtent,
    required this.trailingFloor,
    required this.defaultExtent,
    this.collapsed = false,
    this.semanticLabel = 'Resize pane',
    required this.onCommit,
  });

  @override
  State<ResizablePanePair> createState() => _ResizablePanePairState();
}

class _ResizablePanePairState extends State<ResizablePanePair> {
  double? _gestureExtent;
  double? _keyboardExtent;
  var _bounds = (min: 0.0, max: double.infinity);

  @override
  void didUpdateWidget(ResizablePanePair oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.extent != oldWidget.extent) _keyboardExtent = null;
  }

  void _commitGesture() {
    final value = _gestureExtent;
    if (value == null) return;
    widget.onCommit(value);
    setState(() => _gestureExtent = null);
  }

  void _discardGesture() {
    if (_gestureExtent != null) setState(() => _gestureExtent = null);
  }

  void _adjust(double delta, double rendered) {
    final value = ((_keyboardExtent ?? rendered) + delta)
        .clamp(_bounds.min, _bounds.max)
        .toDouble();
    setState(() => _keyboardExtent = value);
    widget.onCommit(value);
  }

  void _reset() {
    final value = widget.defaultExtent
        .clamp(_bounds.min, _bounds.max)
        .toDouble();
    setState(() {
      _gestureExtent = null;
      _keyboardExtent = value;
    });
    widget.onCommit(value);
  }

  KeyEventResult _handleKey(KeyEvent event, double rendered) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (widget.axis == Axis.horizontal) {
      if (key == LogicalKeyboardKey.arrowLeft) {
        _adjust(-16, rendered);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowRight) {
        _adjust(16, rendered);
        return KeyEventResult.handled;
      }
    } else {
      if (key == LogicalKeyboardKey.arrowUp) {
        _adjust(-16, rendered);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowDown) {
        _adjust(16, rendered);
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = widget.axis == Axis.horizontal
            ? constraints.maxWidth
            : constraints.maxHeight;
        final ceiling = math.max(
          widget.minExtent,
          math.min(widget.maxExtent, available - widget.trailingFloor - 1),
        );
        _bounds = (min: widget.minExtent, max: ceiling);
        var rendered =
            ((_gestureExtent ?? _keyboardExtent ?? widget.extent).clamp(
              widget.minExtent,
              ceiling,
            )).toDouble();
        rendered = math.min(rendered, math.max(0, available - 1));
        final visibleExtent = widget.collapsed ? 0.0 : rendered;
        final divider = _divider(rendered);

        if (widget.axis == Axis.horizontal) {
          return Stack(
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: visibleExtent,
                    child: widget.collapsed ? null : widget.leading,
                  ),
                  Container(width: 1, color: MacosColors.separatorColor),
                  Expanded(child: widget.trailing),
                ],
              ),
              Positioned(
                left: visibleExtent > 0 ? visibleExtent - 4 : 0,
                top: 0,
                bottom: 0,
                width: 9,
                child: divider,
              ),
            ],
          );
        }
        return Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: visibleExtent,
                  child: widget.collapsed ? null : widget.leading,
                ),
                Container(height: 1, color: MacosColors.separatorColor),
                Expanded(child: widget.trailing),
              ],
            ),
            Positioned(
              left: 0,
              right: 0,
              top: visibleExtent > 0 ? visibleExtent - 4 : 0,
              height: 9,
              child: divider,
            ),
          ],
        );
      },
    );
  }

  Widget _divider(double rendered) {
    final horizontal = widget.axis == Axis.horizontal;
    final increaseLabel = '${(rendered + 16).round()} pixels';
    final decreaseLabel = '${math.max(0, rendered - 16).round()} pixels';
    return Semantics(
      slider: true,
      label: widget.semanticLabel,
      value: '${rendered.round()} pixels',
      increasedValue: increaseLabel,
      decreasedValue: decreaseLabel,
      onIncrease: widget.collapsed ? null : () => _adjust(16, rendered),
      onDecrease: widget.collapsed ? null : () => _adjust(-16, rendered),
      customSemanticsActions: {
        const CustomSemanticsAction(label: 'Reset width'): _reset,
      },
      child: Focus(
        onKeyEvent: (_, event) => _handleKey(event, rendered),
        child: MouseRegion(
          cursor: horizontal
              ? SystemMouseCursors.resizeLeftRight
              : SystemMouseCursors.resizeUpDown,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            dragStartBehavior: DragStartBehavior.down,
            onHorizontalDragStart: !horizontal || widget.collapsed
                ? null
                : (_) => setState(() => _gestureExtent = rendered),
            onHorizontalDragUpdate: !horizontal || widget.collapsed
                ? null
                : (details) => setState(() {
                    _gestureExtent =
                        ((_gestureExtent ?? rendered) + details.delta.dx)
                            .clamp(_bounds.min, _bounds.max)
                            .toDouble();
                  }),
            onHorizontalDragEnd: !horizontal || widget.collapsed
                ? null
                : (_) => _commitGesture(),
            onHorizontalDragCancel: !horizontal || widget.collapsed
                ? null
                : _discardGesture,
            onVerticalDragStart: horizontal || widget.collapsed
                ? null
                : (_) => setState(() => _gestureExtent = rendered),
            onVerticalDragUpdate: horizontal || widget.collapsed
                ? null
                : (details) => setState(() {
                    _gestureExtent =
                        ((_gestureExtent ?? rendered) + details.delta.dy)
                            .clamp(_bounds.min, _bounds.max)
                            .toDouble();
                  }),
            onVerticalDragEnd: horizontal || widget.collapsed
                ? null
                : (_) => _commitGesture(),
            onVerticalDragCancel: horizontal || widget.collapsed
                ? null
                : _discardGesture,
            onDoubleTap: widget.collapsed ? null : _reset,
          ),
        ),
      ),
    );
  }
}

/// Compatibility wrapper for existing pane sites backed by global settings.
class ResizableMasterDetail extends ConsumerWidget {
  final PaneId paneId;
  final Widget master;
  final Widget detail;
  final double detailFloor;
  final bool collapsed;

  const ResizableMasterDetail({
    super.key,
    required this.paneId,
    required this.master,
    required this.detail,
    this.detailFloor = 280,
    this.collapsed = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final spec = paneSpecs[paneId]!;
    final stored = ref.watch(
      appSettingsProvider.select((settings) => settings.paneWidth(paneId)),
    );
    return ResizablePanePair(
      axis: Axis.horizontal,
      leading: master,
      trailing: detail,
      extent: stored,
      minExtent: spec.min,
      maxExtent: spec.max,
      trailingFloor: detailFloor,
      defaultExtent: spec.defaultWidth,
      collapsed: collapsed,
      semanticLabel: 'Resize ${paneId.name} pane',
      onCommit: (width) =>
          ref.read(appSettingsProvider.notifier).setPaneWidth(paneId, width),
    );
  }
}
