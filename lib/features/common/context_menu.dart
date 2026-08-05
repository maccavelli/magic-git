import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:macos_ui/macos_ui.dart';
import 'escape_dismissible.dart';
import 'tappable.dart';

/// One entry in a [ContextMenuOverlay]-shown menu: either an actionable
/// [ContextMenuItem] or a visual [ContextMenuDivider] between groups.
sealed class ContextMenuEntry {
  const ContextMenuEntry();
}

/// A single actionable row (icon + label). Disabled rows (e.g. an action
/// that's meaningless for an untracked file) grey out, ignore taps, and
/// optionally explain why via [disabledTooltip].
class ContextMenuItem extends ContextMenuEntry {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool enabled;
  final String? disabledTooltip;

  /// Tints the leading icon (e.g. a red trash can for a destructive action).
  /// Only the icon is tinted, not the label. Ignored while the row is disabled
  /// — a greyed-out row's uniform grey takes precedence.
  final Color? iconColor;
  const ContextMenuItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.enabled = true,
    this.disabledTooltip,
    this.iconColor,
  });
}

/// A thin separator between groups of [ContextMenuItem]s.
class ContextMenuDivider extends ContextMenuEntry {
  const ContextMenuDivider();
}

/// Shows and dismisses a macOS-styled right-click context menu: a
/// translucent full-screen layer (dismisses on any other click) plus a
/// floating card of [ContextMenuEntry]s anchored at the click point, clamped
/// to stay fully on-screen. One controller per widget that wants a
/// right-click menu — hold it as a State field, call [show] from
/// `onSecondaryTapUp`, and call [dispose] from the State's own `dispose()`.
class ContextMenuOverlay {
  OverlayEntry? _entry;
  VoidCallback? _escDisposer;

  bool get isShowing => _entry != null;

  /// Dismisses the menu if one is showing. Safe to call when none is.
  void remove() {
    _escDisposer?.call();
    _escDisposer = null;
    _entry?.remove();
    _entry = null;
  }

  /// Same as [remove] — call from the owning State's `dispose()`.
  void dispose() => remove();

  /// Shows a menu of [entries] anchored at [globalPosition]. Replaces any
  /// menu already showing from this controller.
  ///
  /// [globalPosition] is typically a `TapUpDetails.globalPosition` from
  /// `onSecondaryTapUp`. The card's height isn't known until it's laid out,
  /// so it's estimated from the entry count/type up front (each item ~32px,
  /// each divider ~9px) to decide whether the card needs to flip up/left to
  /// stay on screen — good enough since every entry is a single line.
  void show(
    BuildContext context,
    Offset globalPosition,
    List<ContextMenuEntry> entries, {
    double width = 200,
  }) {
    remove();
    final screen = MediaQuery.sizeOf(context);
    final estimatedHeight = entries.fold<double>(
      8,
      (h, e) => h + (e is ContextMenuDivider ? 9 : 32),
    );
    final left = (globalPosition.dx + width > screen.width)
        ? (screen.width - width).clamp(0.0, screen.width)
        : globalPosition.dx;
    final top = (globalPosition.dy + estimatedHeight > screen.height)
        ? (screen.height - estimatedHeight).clamp(0.0, screen.height)
        : globalPosition.dy;
    final overlay = Overlay.of(context);
    _entry = OverlayEntry(
      builder: (_) => Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: remove,
              onSecondaryTap: remove,
            ),
          ),
          Positioned(
            left: left,
            top: top,
            child: _ContextMenuCard(
              width: width,
              entries: entries,
              onDismiss: remove,
            ),
          ),
        ],
      ),
    );
    overlay.insert(_entry!);
    // Escape closes the menu (like an outside click), and consumes the key so
    // it doesn't also dismiss a sheet/dialog behind the menu.
    _escDisposer = EscapeDismissRegistry.register(() {
      if (_entry == null) return false;
      remove();
      return true;
    });
  }
}

class _ContextMenuCard extends StatefulWidget {
  final double width;
  final List<ContextMenuEntry> entries;
  final VoidCallback onDismiss;
  const _ContextMenuCard({
    required this.width,
    required this.entries,
    required this.onDismiss,
  });

  @override
  State<_ContextMenuCard> createState() => _ContextMenuCardState();
}

class _ContextMenuCardState extends State<_ContextMenuCard> {
  late final FocusNode _focus;
  int _focusedItem = -1;

  List<int> get _actionIndexes {
    final out = <int>[];
    for (var i = 0; i < widget.entries.length; i++) {
      final e = widget.entries[i];
      if (e is ContextMenuItem && e.enabled) out.add(i);
    }
    return out;
  }

  @override
  void initState() {
    super.initState();
    _focus = FocusNode(debugLabel: 'context-menu');
    final actions = _actionIndexes;
    if (actions.isNotEmpty) _focusedItem = actions.first;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final actions = _actionIndexes;
    if (actions.isEmpty) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      widget.onDismiss();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowUp) {
      final dir = key == LogicalKeyboardKey.arrowDown ? 1 : -1;
      final pos = actions.indexOf(_focusedItem);
      final next = (pos < 0 ? 0 : pos + dir).clamp(0, actions.length - 1);
      setState(() => _focusedItem = actions[next]);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.space) {
      final e = widget.entries[_focusedItem];
      if (e is ContextMenuItem && e.enabled) {
        widget.onDismiss();
        e.onTap();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final brightness = MacosTheme.brightnessOf(context);
    final surface = brightness == Brightness.dark
        ? const Color(0xFF2C2C2E)
        : const Color(0xFFF5F5F7);
    return Focus(
      focusNode: _focus,
      onKeyEvent: _onKey,
      child: SizedBox(
        width: widget.width,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: MacosColors.separatorColor),
            boxShadow: [
              BoxShadow(
                color: brightness == Brightness.dark
                    ? const Color(0x66000000)
                    : const Color(0x33000000),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height - 16,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < widget.entries.length; i++)
                    switch (widget.entries[i]) {
                      ContextMenuDivider() => Container(
                        height: 1,
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        color: MacosColors.separatorColor,
                      ),
                      final ContextMenuItem e => _ContextMenuRow(
                        icon: e.icon,
                        label: e.label,
                        enabled: e.enabled,
                        disabledTooltip: e.disabledTooltip,
                        iconColor: e.iconColor,
                        focused: i == _focusedItem,
                        onTap: () {
                          widget.onDismiss();
                          e.onTap();
                        },
                      ),
                    },
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ContextMenuRow extends StatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool enabled;
  final String? disabledTooltip;
  final Color? iconColor;
  final bool focused;
  const _ContextMenuRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.enabled = true,
    this.disabledTooltip,
    this.iconColor,
    this.focused = false,
  });

  @override
  State<_ContextMenuRow> createState() => _ContextMenuRowState();
}

class _ContextMenuRowState extends State<_ContextMenuRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled;
    final color = enabled ? null : MacosColors.systemGrayColor;
    // A disabled row greys everything uniformly; an enabled row lets an
    // explicit iconColor (e.g. a red trash can) tint just the icon.
    final iconColor = enabled ? widget.iconColor : color;
    final highlight = (_hover || widget.focused) && enabled;
    final row = Tappable(
      onEnter: enabled ? (_) => setState(() => _hover = true) : null,
      onExit: enabled ? (_) => setState(() => _hover = false) : null,
      onTap: enabled ? widget.onTap : null,
      behavior: HitTestBehavior.opaque,
      child: Container(
        color: highlight
            ? MacosColors.systemBlueColor.withValues(alpha: 0.25)
            : const Color(0x00000000),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Row(
          children: [
            MacosIcon(widget.icon, size: 14, color: iconColor),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                widget.label,
                style: MacosTheme.of(
                  context,
                ).typography.body.copyWith(color: color),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
    if (enabled || widget.disabledTooltip == null) return row;
    return MacosTooltip(message: widget.disabledTooltip!, child: row);
  }
}
