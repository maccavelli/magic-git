import 'package:flutter/widgets.dart';

/// Scrolls the widget behind [key] into view after the current frame, if it is
/// laid out. Used for arrow-key list navigation: moving the selection one row
/// at a time keeps the target within the list's `cacheExtent`, so its context
/// is built and `Scrollable.ensureVisible` can reach it even when the row is
/// just off-screen. A no-op when the row isn't currently built (a large jump) —
/// the selection still moves; only the auto-scroll is skipped.
///
/// Honors Reduce Motion: when animations are disabled, jumps without duration.
void ensureRowVisible(
  GlobalKey key, {
  double alignment = 0.5,
  bool reduceMotion = false,
}) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    final ctx = key.currentContext;
    if (ctx == null) return;
    final disable =
        reduceMotion || MediaQuery.maybeOf(ctx)?.disableAnimations == true;
    Scrollable.ensureVisible(
      ctx,
      alignment: alignment,
      duration: disable ? Duration.zero : const Duration(milliseconds: 90),
      curve: Curves.easeOut,
    );
  });
}

/// Moves a selection index by [delta] within a list of [count] items. With
/// nothing selected ([current] < 0), Down lands on the first item and Up on the
/// last; otherwise it steps and clamps at the ends (no wrap). Returns the new
/// index, or -1 when the list is empty.
int stepSelection(int current, int delta, int count) {
  if (count == 0) return -1;
  if (current < 0) return delta > 0 ? 0 : count - 1;
  return (current + delta).clamp(0, count - 1);
}
