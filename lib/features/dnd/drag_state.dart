import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'drag_item.dart';

/// What is currently being dragged, or null when nothing is. Set by
/// [DragItemDraggable] on drag start and cleared on end, so reactive drop
/// targets — chiefly the nav rail — can highlight the zones that would accept
/// the payload the instant a drag begins (before the pointer reaches them).
///
/// **ESC cancels the drag**: while a drag is live a hardware-keyboard handler
/// clears this state on Escape. Flutter can't abort the gesture itself (the
/// ghost follows the pointer until release), but every drop target treats a
/// null drag state as "cancelled" and ignores the drop, and the nav rail
/// un-lights immediately — so ESC makes releasing anywhere a guaranteed no-op.
///
/// **Over a target** ([overTarget], MADR 0064 F2): every drop target reports
/// whether the pointer is over it *and it accepts the payload*, so the drag
/// image can collapse to its compact chip beside the pointer instead of
/// covering the very target it is over.
class DragStateNotifier extends Notifier<DragItem?> {
  bool _escHandlerInstalled = false;

  @override
  DragItem? build() {
    // A tab (container) can be torn down mid-drag; never leak the handler.
    ref.onDispose(_removeEscHandler);
    return null;
  }

  void begin(DragItem item) {
    state = item;
    if (!_escHandlerInstalled) {
      HardwareKeyboard.instance.addHandler(_onKey);
      _escHandlerInstalled = true;
    }
  }

  /// Whether a drag is still live (not ESC-cancelled). Readable through the
  /// notifier — which stays valid even if the reading widget's element was
  /// unmounted mid-drag — so [DragItemDraggable.end] can tell an accepted drop
  /// from a cancelled one that happened to be released over a target.
  bool get isActive => state != null;

  /// Whether the pointer is over a drop target that accepts the live payload.
  /// A [ValueNotifier] rather than provider state: the drag image is built
  /// once as the Draggable's feedback, and only a listenable can update it.
  /// Synchronous, so the image switches in the same frame the target lights.
  final ValueNotifier<bool> overTarget = ValueNotifier(false);

  /// The target that last reported hover (its [DragHoverReport]), so only
  /// that target can take the hover back.
  Object? _overTargetOwner;

  /// Called by every drop target for a drag item, through its own
  /// [DragHoverReport]: `true` from `onMove` — guarded by the target's own
  /// acceptance test, because Flutter calls `onMove` on rejecting targets
  /// too — and `false` from `onLeave` and on accept.
  ///
  /// `true` makes [owner] the holder. `false` from an [owner] that no
  /// longer holds the hover is ignored; a `false` with no owner clears it
  /// unconditionally. A `true` while no drag is live (ESC already
  /// cancelled it) is ignored, so moving after ESC cannot bring the chip
  /// back.
  void setOverTarget(bool value, {Object? owner}) {
    if (value) {
      if (state == null) return;
      _overTargetOwner = owner;
      overTarget.value = true;
      return;
    }
    if (owner != null && !identical(owner, _overTargetOwner)) return;
    _clearOverTarget();
  }

  /// A drop target is leaving the tree. Flutter never calls `onLeave` on an
  /// unmounted target, so this is the only way the hover it holds comes
  /// back. Deferred to the end of the frame: a target is disposed while
  /// the widget tree is locked, when the drag image cannot be marked for
  /// rebuild. No-op unless [owner] still holds the hover then.
  void releaseOverTarget(Object owner) {
    if (!identical(owner, _overTargetOwner)) return;
    SchedulerBinding.instance
      ..addPostFrameCallback((_) {
        if (identical(owner, _overTargetOwner)) _clearOverTarget();
      })
      ..ensureVisualUpdate();
  }

  void _clearOverTarget() {
    _overTargetOwner = null;
    overTarget.value = false;
  }

  /// Called on every drag end (drop or cancel). Idempotent — an ESC-cancelled
  /// drag still ends with a pointer release, which calls this again.
  void end() {
    state = null;
    _clearOverTarget();
    _removeEscHandler();
  }

  bool _onKey(KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape &&
        state != null) {
      state = null; // drop targets now ignore the release; the rail un-lights
      _clearOverTarget(); // the full drag image returns at once
      return true; // swallow it — this ESC must not also dismiss a sheet
    }
    return false;
  }

  void _removeEscHandler() {
    if (_escHandlerInstalled) {
      HardwareKeyboard.instance.removeHandler(_onKey);
      _escHandlerInstalled = false;
    }
  }
}

/// One drop target's hover report: the handle a [DragHoverScope] gives the
/// target it wraps. Reporting through it makes that target the owner, so
/// its [dispose] clears the hover only while it still holds it.
class DragHoverReport {
  final DragStateNotifier _drag;

  DragHoverReport(this._drag);

  /// See [DragStateNotifier.setOverTarget].
  void setOverTarget(bool value) => _drag.setOverTarget(value, owner: this);

  /// The target is leaving the tree: give back the hover if it holds it.
  void dispose() => _drag.releaseOverTarget(this);
}

final dragStateProvider = NotifierProvider<DragStateNotifier, DragItem?>(
  DragStateNotifier.new,
);
