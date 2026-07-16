import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'palette_intents.dart';

/// A [CallbackShortcuts] stand-in for panel-scoped bindings that yields to
/// text interaction — and the consumption point for palette-dispatched
/// panel actions.
///
/// Panel shortcut maps wrap the whole panel — including its text fields and
/// selectable diff/log panes. Key events resolve nearest-ancestor-first, so a
/// panel binding on a text-editing key would win over the app root's
/// `DefaultTextEditingShortcuts` and hijack standard macOS editing keys:
/// ⌘⌫ (delete to line start) fired Delete Branch, ⌘C (copy) copied a commit
/// SHA instead of the selected text, and Space toggled staging from inside a
/// selectable diff. When the primary focus sits inside an [EditableText] or a
/// [SelectionArea], every panel binding is skipped so the event bubbles on to
/// the platform text-editing handlers; panel shortcuts resume the moment focus
/// leaves the field. Dialog/sheet-scoped shortcuts (commit ⌘↩ etc.) keep
/// using [CallbackShortcuts] deliberately — those are meant to fire while
/// typing.
///
/// [handlers] is the same action-id → handler map the panel feeds
/// `resolveShortcuts` (pass it only while the panel is active, exactly like
/// [bindings]). It is what lets the command palette run panel actions: the
/// palette parks an action id in [paletteIntentProvider], and the owning
/// panel's PanelShortcuts consumes it here — through the very same handler
/// (and thus the same busy/selection guards) its keyboard shortcut uses.
class PanelShortcuts extends ConsumerStatefulWidget {
  const PanelShortcuts({
    super.key,
    required this.bindings,
    this.handlers = const {},
    required this.child,
  });

  final Map<ShortcutActivator, VoidCallback> bindings;
  final Map<String, VoidCallback?> handlers;
  final Widget child;

  /// Whether the currently focused node lives inside an editable text field or
  /// a selection region — i.e. the user is interacting with text and expects
  /// the standard editing/copy keys to keep their meaning.
  static bool textInteractionHasFocus() {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return false;
    return context.findAncestorStateOfType<EditableTextState>() != null ||
        context.findAncestorWidgetOfExactType<SelectionArea>() != null;
  }

  @override
  ConsumerState<PanelShortcuts> createState() => _PanelShortcutsState();
}

class _PanelShortcutsState extends ConsumerState<PanelShortcuts> {
  bool _consumeScheduled = false;

  /// Consumption always runs post-frame: from build it must not mutate the
  /// intent provider mid-build, and the handler itself may setState/navigate.
  /// One flag dedupes the listen-path and build-path both scheduling in the
  /// same frame.
  void _scheduleConsume() {
    if (_consumeScheduled || widget.handlers.isEmpty) return;
    _consumeScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _consumeScheduled = false;
      if (!mounted) return;
      final handler = ref
          .read(paletteIntentProvider.notifier)
          .consume(widget.handlers);
      handler?.call();
    });
  }

  @override
  Widget build(BuildContext context) {
    // Dispatched while this panel is already active and built.
    ref.listen(paletteIntentProvider, (_, intent) {
      if (intent != null) _scheduleConsume();
    });
    // Dispatched before this panel (re)built with live handlers — the palette
    // switches panels first, so the intent is usually already parked by the
    // time the newly-active panel builds.
    if (ref.read(paletteIntentProvider) != null) _scheduleConsume();

    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        if (widget.bindings.isEmpty ||
            PanelShortcuts.textInteractionHasFocus()) {
          return KeyEventResult.ignored;
        }
        for (final MapEntry(key: activator, value: callback)
            in widget.bindings.entries) {
          if (activator.accepts(event, HardwareKeyboard.instance)) {
            callback();
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: widget.child,
    );
  }
}
