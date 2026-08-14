import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/providers/app_providers.dart';
import '../../core/settings/keymap.dart';
import '../../core/undo/undo_journal.dart';
import '../../core/undo/undo_types.dart';
import 'tappable.dart';

/// One transient toast: what happened, and whether ⌘Z applies to it.
class UndoToast {
  final String message;

  /// Renders the "⌘Z to undo" affordance and makes the toast click-to-undo.
  /// False for pure announcements ("Undid: Commit") and for operations whose
  /// undo capture degraded.
  final bool showUndoHint;

  /// True only when the completed undo generated an atomic [RedoRecord].
  /// Unsupported operation kinds never expose a best-effort action.
  final bool showRedoHint;

  const UndoToast(
    this.message, {
    this.showUndoHint = false,
    this.showRedoHint = false,
  }) : assert(!showUndoHint || !showRedoHint);
}

/// Owns the toast's visibility window: [show] replaces whatever is up and
/// restarts the auto-dismiss clock (latest wins); hovering pauses it so the
/// click target can't vanish mid-aim.
class UndoToastNotifier extends Notifier<UndoToast?> {
  static const visibleFor = Duration(seconds: 5);
  Timer? _timer;

  @override
  UndoToast? build() {
    ref.onDispose(() => _timer?.cancel());
    return null;
  }

  void show(UndoToast toast) {
    _timer?.cancel();
    state = toast;
    _timer = Timer(visibleFor, dismiss);
  }

  void dismiss() {
    _timer?.cancel();
    _timer = null;
    state = null;
  }

  void pause() {
    _timer?.cancel();
    _timer = null;
  }

  void resume() {
    if (state != null) {
      _timer?.cancel();
      _timer = Timer(visibleFor, dismiss);
    }
  }
}

final undoToastProvider = NotifierProvider<UndoToastNotifier, UndoToast?>(
  UndoToastNotifier.new,
);

/// The bottom-center toast layer, mounted once in AppShell's Stack. Shows an
/// "`<operation>` — ⌘Z to undo" toast whenever the undo journal grows for the
/// active repo (the journal is the single choke point every undoable mutation
/// feeds, so no mutation call site needs to know toasts exist), and whatever
/// [UndoToastNotifier.show] is handed directly ("Undid: …" from the ⌘Z
/// handler). Clicking a hinted toast runs [onUndo] — the same handler ⌘Z
/// invokes.
class UndoToastOverlay extends ConsumerStatefulWidget {
  final Future<void> Function() onUndo;
  final Future<void> Function()? onRedo;

  const UndoToastOverlay({super.key, required this.onUndo, this.onRedo});

  @override
  ConsumerState<UndoToastOverlay> createState() => _UndoToastOverlayState();
}

class _UndoToastOverlayState extends ConsumerState<UndoToastOverlay> {
  /// The last non-null toast, retained so the fade-out animates real content
  /// instead of collapsing the moment the provider clears.
  UndoToast? _lastShown;

  @override
  Widget build(BuildContext context) {
    ref.listen(undoJournalProvider, (previous, next) {
      final repoPath = ref.read(connectionProvider).repoPath;
      if (repoPath == null) return;
      final before = previous?[repoPath]?.length ?? 0;
      final stack = next[repoPath];
      // Only a *growing* stack is a new operation — pops (an executed undo,
      // a discarded stale record) announce themselves separately or not at
      // all.
      if (stack == null || stack.isEmpty || stack.length <= before) return;
      final record = stack.last;
      // A mutation performed in the History window already raised its own
      // toast there; skip the redundant one here (see historyOriginUndoProvider).
      if (ref.read(historyOriginUndoProvider.notifier).take(record)) return;
      ref
          .read(undoToastProvider.notifier)
          .show(UndoToast(record.description, showUndoHint: true));
    });

    final toast = ref.watch(undoToastProvider);
    if (toast != null) _lastShown = toast;
    final shown = _lastShown;
    final visible = toast != null && shown != null;

    return Positioned(
      left: 0,
      right: 0,
      bottom: 28,
      child: IgnorePointer(
        ignoring: !visible,
        child: AnimatedSlide(
          offset: visible ? Offset.zero : const Offset(0, 0.3),
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          child: AnimatedOpacity(
            opacity: visible ? 1 : 0,
            duration: const Duration(milliseconds: 160),
            child: Center(
              child: shown == null ? const SizedBox.shrink() : _pill(shown),
            ),
          ),
        ),
      ),
    );
  }

  Widget _pill(UndoToast toast) {
    final typography = MacosTheme.of(context).typography;
    final brightness = MacosTheme.brightnessOf(context);
    final notifier = ref.read(undoToastProvider.notifier);
    // Render the *live* binding, not a hardcoded ⌘Z — the keymap is
    // user-remappable.
    final actionId = toast.showRedoHint ? 'global.redo' : 'global.undo';
    final bindings = ref.watch(keymapProvider)[actionId];
    final hintLabel = (bindings != null && bindings.isNotEmpty)
        ? bindings.first.label
        : null;

    return Tappable(
      onEnter: (_) => notifier.pause(),
      onExit: (_) => notifier.resume(),
      // Defer (not arrow) while the hint is hidden: the toast is dismissable
      // but not advertising an action yet.
      cursor: toast.showUndoHint || toast.showRedoHint
          ? SystemMouseCursors.click
          : MouseCursor.defer,
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (toast.showUndoHint) {
          notifier.dismiss();
          widget.onUndo();
        } else if (toast.showRedoHint && widget.onRedo != null) {
          notifier.dismiss();
          widget.onRedo!();
        } else {
          notifier.dismiss();
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: brightness.resolve(
            CupertinoColors.systemGrey6.color,
            MacosColors.controlBackgroundColor.darkColor,
          ),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: MacosColors.separatorColor),
          boxShadow: const [
            BoxShadow(
              color: Color(0x33000000),
              blurRadius: 16,
              offset: Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(toast.message, style: typography.body),
            if ((toast.showUndoHint || toast.showRedoHint) &&
                hintLabel != null) ...[
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(color: MacosColors.separatorColor),
                ),
                child: Text(hintLabel, style: typography.caption1),
              ),
              const SizedBox(width: 6),
              Text(
                toast.showRedoHint ? 'to redo' : 'to undo',
                style: typography.caption1.copyWith(
                  color: MacosColors.systemGrayColor,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
