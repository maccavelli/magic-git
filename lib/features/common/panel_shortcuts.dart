import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A [CallbackShortcuts] stand-in for panel-scoped bindings that yields to
/// text interaction.
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
class PanelShortcuts extends StatelessWidget {
  const PanelShortcuts({
    super.key,
    required this.bindings,
    required this.child,
  });

  final Map<ShortcutActivator, VoidCallback> bindings;
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
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        if (bindings.isEmpty || textInteractionHasFocus()) {
          return KeyEventResult.ignored;
        }
        for (final MapEntry(key: activator, value: callback)
            in bindings.entries) {
          if (activator.accepts(event, HardwareKeyboard.instance)) {
            callback();
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: child,
    );
  }
}
