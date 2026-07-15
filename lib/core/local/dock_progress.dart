import 'dart:async';

import 'package:window_manager/window_manager.dart';

/// Mirrors long-running network operations onto the macOS Dock icon's
/// progress bar (an `NSDockTile` indicator drawn by window_manager).
///
/// Two inputs compose into one bar:
///
///  * [track] counts in-flight operations — any count > 0 shows an
///    indeterminate bar, the "still talking to the network" signal for ops
///    git reports no percentages for (fetch, push, pull, tag pushes).
///  * [setFraction] overrides with a determinate 0..1 value while an op that
///    DOES know its progress runs (clone parses git's transfer percentages).
///
/// One instance per isolate, shared by every tab's provider container — the
/// Dock is per-app, not per-tab, so overlapping ops from two tabs must keep
/// the bar up until the LAST one finishes. Draw failures (tests, plugin
/// unavailable) are swallowed: the Dock is cosmetic, never load-bearing.
class DockProgress {
  DockProgress._();

  static final DockProgress instance = DockProgress._();

  /// window_manager's macOS contract: a value < 0 hides the bar, a value > 1
  /// switches the indicator to indeterminate, and 0..1 is a determinate
  /// fraction.
  static const double hidden = -1;
  static const double indeterminate = 2;

  /// The send seam — tests swap in a recorder; null means the real Dock.
  /// The default is resolved lazily inside [_apply]: merely touching
  /// [windowManager] constructs its singleton, which needs a Flutter binding
  /// pure unit tests don't have.
  Future<void> Function(double value)? sendOverride;

  int _inFlight = 0;
  double? _fraction;
  double? _lastSent;

  /// Runs [op] with the in-flight counter held: the bar shows for the whole
  /// span and hides only when the last overlapping tracked op finishes.
  Future<T> track<T>(Future<T> Function() op) async {
    _inFlight++;
    _apply();
    try {
      return await op();
    } finally {
      _inFlight--;
      // Backstop: a determinate fraction cannot outlive every op that could
      // have owned it.
      if (_inFlight == 0) _fraction = null;
      _apply();
    }
  }

  /// Determinate override while a tracked op knows its own progress.
  void setFraction(double value) {
    _fraction = value.clamp(0.0, 1.0);
    _apply();
  }

  /// Drops the determinate override — back to whatever the counter implies.
  void clearFraction() {
    if (_fraction == null) return;
    _fraction = null;
    _apply();
  }

  void _apply() {
    final value = _fraction ?? (_inFlight > 0 ? indeterminate : hidden);
    if (value == _lastSent) return;
    _lastSent = value;
    unawaited(() async {
      try {
        await (sendOverride ?? windowManager.setProgressBar)(value);
      } catch (_) {
        // No Dock to draw on — cosmetic, move on.
      }
    }());
  }

  /// Restores pristine state — including the production sender; tests call
  /// this between cases.
  void reset() {
    _inFlight = 0;
    _fraction = null;
    _lastSent = null;
    sendOverride = null;
  }
}
