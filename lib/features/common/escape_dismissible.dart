import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Handles the Escape key, returning true if it consumed it (so nothing beneath
/// it in the stack should also react).
typedef EscapeHandler = bool Function();

/// A single, app-wide Escape-key dispatcher backed by a LIFO stack of open
/// popups. The most recently opened popup is offered the key first and, if it
/// handles it, consumes it — so a foreground dialog/menu closes without also
/// popping the sheet behind it, and one Escape closes exactly one layer.
///
/// Why [HardwareKeyboard] rather than the focus tree (`Focus.onKeyEvent` /
/// `Shortcuts` / `CallbackShortcuts`): a key event only reaches a focus-based
/// handler by bubbling up from whatever currently holds focus, and a focused
/// text/selection field (e.g. the `SelectableText` inside a diff view) can
/// handle or swallow Escape at the platform layer before it ever bubbles to an
/// ancestor. That makes a focus-based dismiss silently fail the moment the user
/// clicks into such content. A [HardwareKeyboard] handler sees the raw key
/// regardless of what holds focus, so dismissal is reliable.
class EscapeDismissRegistry {
  EscapeDismissRegistry._();

  static final List<EscapeHandler> _stack = [];

  /// Whether any Escape consumer (sheet, pop-out window, menu) is currently
  /// open. Panel-level Escape fallbacks — deselect, see dnd/deselect.dart —
  /// must stand down while one is: the registry runs off [HardwareKeyboard],
  /// which fires BEFORE the focus tree sees the same key event, so without
  /// this check a single Escape would close the overlay AND fall through to
  /// the panel. One Escape closes exactly one layer.
  static bool get isActive => _stack.isNotEmpty;

  /// Pushes [handler] onto the top of the stack and returns a disposer that
  /// removes it. Call the disposer when the popup closes. The handler is
  /// offered Escape before any registered earlier.
  ///
  /// The underlying [HardwareKeyboard] handler is attached only while the stack
  /// is non-empty (and detached when it empties again) rather than once-forever
  /// behind a static flag — the latter desyncs if the handler is ever cleared
  /// out from under us (as the test binding does between tests).
  static VoidCallback register(EscapeHandler handler) {
    if (_stack.isEmpty) {
      HardwareKeyboard.instance.addHandler(_onKey);
    }
    _stack.add(handler);
    var removed = false;
    return () {
      // Idempotent, and identity-based so re-registering the same closure
      // elsewhere can't cause this disposer to drop the wrong entry.
      if (removed) return;
      removed = true;
      _stack.remove(handler);
      if (_stack.isEmpty) {
        HardwareKeyboard.instance.removeHandler(_onKey);
      }
    };
  }

  static bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape) {
      return false;
    }
    // Snapshot before dispatch: a handler that closes its popup deregisters
    // itself mid-iteration, which would otherwise mutate the list we're walking.
    final snapshot = List<EscapeHandler>.of(_stack);
    for (var i = snapshot.length - 1; i >= 0; i--) {
      if (snapshot[i]()) return true;
    }
    return false;
  }
}

/// Wraps a sheet/dialog so Escape pops it — the standard macOS dismiss key,
/// which `showMacosSheet` / `showMacosAlertDialog` don't provide on their own.
///
/// Dismissal is routed through [EscapeDismissRegistry], so it works no matter
/// what holds focus inside the sheet (including a focused, selectable diff) and
/// never touches focus itself. A descendant that needs Escape for its own
/// purpose (e.g. cancelling an in-progress key recording) can register an
/// interceptor via [EscapeInterceptor.of].
class EscapeDismissible extends StatefulWidget {
  final Widget child;
  const EscapeDismissible({super.key, required this.child});

  @override
  State<EscapeDismissible> createState() => _EscapeDismissibleState();
}

class _EscapeDismissibleState extends State<EscapeDismissible> {
  final List<EscapeHandler> _interceptors = [];
  VoidCallback? _unregister;
  ModalRoute<dynamic>? _route;

  @override
  void initState() {
    super.initState();
    _unregister = EscapeDismissRegistry.register(_handleEscape);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Captured here (during a build lifecycle) so the Escape handler, which
    // runs outside build, doesn't call ModalRoute.of from a raw key callback.
    _route = ModalRoute.of(context);
  }

  @override
  void dispose() {
    _unregister?.call();
    super.dispose();
  }

  void _addInterceptor(EscapeHandler h) => _interceptors.add(h);
  void _removeInterceptor(EscapeHandler h) => _interceptors.remove(h);

  bool _handleEscape() {
    if (!mounted) return false;
    // Only the frontmost route reacts. The registry's LIFO order usually
    // already ensures this, but a non-EscapeDismissible route (or an overlay)
    // layered on top must still win over a sheet beneath it.
    final route = _route;
    if (route != null && !route.isCurrent) return false;
    // A descendant may claim Escape for itself rather than dismiss the sheet.
    for (var i = _interceptors.length - 1; i >= 0; i--) {
      if (_interceptors[i]()) return true;
    }
    final nav = Navigator.of(context);
    if (nav.canPop()) {
      nav.pop();
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return EscapeInterceptor._(
      add: _addInterceptor,
      remove: _removeInterceptor,
      child: widget.child,
    );
  }
}

/// Exposed by an [EscapeDismissible] to its subtree so a descendant can
/// temporarily consume the Escape key itself — returning true from its handler
/// to keep the sheet open — instead of letting Escape dismiss the whole sheet.
class EscapeInterceptor extends InheritedWidget {
  final void Function(EscapeHandler) _add;
  final void Function(EscapeHandler) _remove;

  // A private field can't be a named initializing formal (named parameters
  // can't start with `_`), so these assignments are unavoidable.
  const EscapeInterceptor._({
    required void Function(EscapeHandler) add,
    required void Function(EscapeHandler) remove,
    required super.child,
    // ignore: prefer_initializing_formals
  }) : _add = add,
       // ignore: prefer_initializing_formals
       _remove = remove;

  /// Registers [handler] and returns a disposer, or null if there is no
  /// enclosing [EscapeDismissible]. The disposer stays valid across rebuilds
  /// because it delegates to the (stable) [EscapeDismissible] state, so it is
  /// safe to call from `dispose()`.
  static VoidCallback? of(BuildContext context, EscapeHandler handler) {
    final scope = context.getInheritedWidgetOfExactType<EscapeInterceptor>();
    if (scope == null) return null;
    scope._add(handler);
    final remove = scope._remove;
    return () => remove(handler);
  }

  @override
  bool updateShouldNotify(EscapeInterceptor oldWidget) =>
      _add != oldWidget._add || _remove != oldWidget._remove;
}
