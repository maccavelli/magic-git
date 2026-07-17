import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../common/escape_dismissible.dart';

/// Canonical deselect affordances (July 2026). Select-on-drag means an
/// abandoned drag leaves its selection behind, so every selectable panel
/// (files, commits, branches, stashes) offers the same two ways OUT of a
/// selection without touching another row:
///
///  * **Esc** — each panel's list key handler clears its selection on Escape
///    (an `escape` case in its `_on*Key`). While a drag is live, the shared
///    drag-state ESC handler has ALREADY nulled the drag by the time the
///    focus tree sees the same key event: HardwareKeyboard handlers run
///    before focus dispatch, and focus dispatch runs regardless of their
///    result (KeyEventManager ORs both). So one press is a full abort — the
///    ghost snaps back, the rail un-lights, and the selection clears.
///  * **Click on empty space** — [DeselectOnEmptyClick] wrapped around the
///    panel's list. Finder's convention: a primary click that none of the
///    list's own rows or controls claim deselects.
///
/// A third affordance was considered and rejected (user decision, July 2026):
/// a plain re-click on the selected row toggling it off. It's nonstandard for
/// macOS lists and fights the click-collapses-multi-selection convention.
///
/// Escape therefore peels layers outermost-first: an open overlay (sheet /
/// pop-out / menu) closes first, a live drag cancels (together with the
/// selection it created — one press aborts the whole gesture), and only then
/// does a bare selection clear.

/// The canonical Escape step for a panel's list key handler — every panel's
/// `_on*Key` returns this from its `escape` case so the layering above stays
/// identical everywhere.
KeyEventResult escDeselect({
  required bool hasSelection,
  required VoidCallback clear,
}) {
  // An overlay Escape consumer is open: this press belongs to it (the
  // registry's HardwareKeyboard handler has already closed one layer by the
  // time the focus tree delivers the same event here).
  if (EscapeDismissRegistry.isActive) return KeyEventResult.ignored;
  if (!hasSelection) return KeyEventResult.ignored;
  clear();
  return KeyEventResult.handled;
}

class DeselectOnEmptyClick extends StatelessWidget {
  /// Clears the panel's selection. Called only for clicks on empty space, but
  /// must be safe to call with nothing selected (a no-op setState).
  final VoidCallback onDeselect;

  final Widget child;

  const DeselectOnEmptyClick({
    super.key,
    required this.onDeselect,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    // translucent: empty (unpainted) areas still hit-test, while deeper tap
    // recognizers — rows, buttons, text fields — win the gesture arena, so
    // this fires only for clicks nothing else claims. Scrolling is unaffected:
    // a tap recognizer yields to the scrollable's drag recognizer on movement.
    //
    // RawGestureDetector rather than GestureDetector: this wraps a whole
    // panel, and adding a GestureDetector ANCESTOR to every row would break
    // the established way of addressing a row ("the GestureDetector above
    // this row's text") in tests and any future ancestor-walking code.
    return RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      gestures: <Type, GestureRecognizerFactory>{
        TapGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
              () => TapGestureRecognizer(debugOwner: this),
              (recognizer) => recognizer.onTap = onDeselect,
            ),
      },
      child: child,
    );
  }
}
