import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Wraps a sheet/dialog so Escape pops it — the standard macOS dismiss key,
/// which `showMacosSheet` doesn't provide on its own.
///
/// Focus handling is the tricky part: the Escape handler must see the key even
/// when the sheet has no focusable content, but it must not steal focus from a
/// sheet that autofocuses a text field. So it never autofocuses; instead, after
/// the first frame, it takes focus only if nothing else in the sheet already
/// has it. A sheet with an autofocused field keeps that field focused (Escape
/// bubbles up from there); a display-only sheet gets this node focused so
/// Escape still lands.
class EscapeDismissible extends StatefulWidget {
  final Widget child;
  const EscapeDismissible({super.key, required this.child});

  @override
  State<EscapeDismissible> createState() => _EscapeDismissibleState();
}

class _EscapeDismissibleState extends State<EscapeDismissible> {
  final _node = FocusNode(skipTraversal: true, debugLabel: 'escape-dismiss');

  @override
  void initState() {
    super.initState();
    // Adopt focus only if nothing in the sheet does — so a display-only sheet
    // can still catch Escape, without stealing an autofocused field's focus.
    // A field's autofocus is applied on a microtask that drains *after* this
    // frame's post-frame callbacks, so the check is queued as a microtask from
    // the post-frame: that lands it after the autofocus microtask, so
    // hasFocus() reflects the field having already claimed focus.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      scheduleMicrotask(() {
        if (mounted && FocusScope.of(context).focusedChild == null) {
          _node.requestFocus();
        }
      });
    });
  }

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyUpEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      final nav = Navigator.of(context);
      if (nav.canPop()) {
        nav.pop();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _node,
      onKeyEvent: _onKey,
      child: widget.child,
    );
  }
}
