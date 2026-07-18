import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../common/tappable.dart';
import 'drag_state.dart';
import 'drop_registry.dart';
import 'drop_zone.dart';

/// One nav-rail entry: an icon, its resting label, and the drop zone it hosts.
class NavRailItem {
  final IconData icon;
  final String label;
  final DropZoneId zone;
  const NavRailItem({
    required this.icon,
    required this.label,
    required this.zone,
  });
}

/// A custom sidebar tab list that replaces `macos_ui` `SidebarItems` so each row
/// can be an individual [DropZone]. Idle, it looks and behaves like the native
/// item list (icon + label, selected accent pill, hover tint, tap to switch).
/// While a drag is live it turns into a launchpad: rows that would accept the
/// payload brighten and relabel to the action ("New branch"), the rest dim.
class NavRail extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onChanged;
  final List<NavRailItem> items;
  final ScrollController? controller;

  /// Post-drop navigation + repo-refresh hooks, forwarded to each row's zone.
  final void Function(int pageIndex) selectPage;
  final VoidCallback refresh;

  const NavRail({
    super.key,
    required this.currentIndex,
    required this.onChanged,
    required this.items,
    required this.selectPage,
    required this.refresh,
    this.controller,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      controller: controller,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
      children: [
        for (var i = 0; i < items.length; i++)
          _NavRow(
            item: items[i],
            selected: i == currentIndex,
            onTap: () => onChanged(i),
            selectPage: selectPage,
            refresh: refresh,
          ),
      ],
    );
  }
}

class _NavRow extends ConsumerWidget {
  final NavRailItem item;
  final bool selected;
  final VoidCallback onTap;
  final void Function(int pageIndex) selectPage;
  final VoidCallback refresh;

  const _NavRow({
    required this.item,
    required this.selected,
    required this.onTap,
    required this.selectPage,
    required this.refresh,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final drag = ref.watch(dragStateProvider);
    final eligible = drag != null && canDrop(drag, item.zone);
    final verb = eligible ? dropVerb(drag, item.zone) : null;
    // Something is being dragged but this row can't take it -> recede.
    final dimmed = drag != null && !eligible;

    return DropZone(
      id: item.zone,
      selectPage: selectPage,
      refresh: refresh,
      builder: (context, hovering) => _NavRowVisual(
        icon: item.icon,
        label: verb ?? item.label,
        selected: selected,
        eligible: eligible,
        activeDrop: hovering && eligible,
        dimmed: dimmed,
        onTap: onTap,
      ),
    );
  }
}

class _NavRowVisual extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final bool eligible;
  final bool activeDrop;
  final bool dimmed;
  final VoidCallback onTap;

  const _NavRowVisual({
    required this.icon,
    required this.label,
    required this.selected,
    required this.eligible,
    required this.activeDrop,
    required this.dimmed,
    required this.onTap,
  });

  @override
  State<_NavRowVisual> createState() => _NavRowVisualState();
}

class _NavRowVisualState extends State<_NavRowVisual> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;

    // Precedence: an active drop hover > drag-eligible > selected > mouse hover.
    // The selected pill uses the THEME's accent (like macos_ui SidebarItems),
    // not a hard-coded blue, so it follows any future accent change in one spot.
    Color? bg;
    if (widget.activeDrop) {
      bg = MacosColors.systemGreenColor.withValues(alpha: 0.32);
    } else if (widget.eligible) {
      bg = MacosColors.systemGreenColor.withValues(alpha: 0.16);
    } else if (widget.selected) {
      bg = MacosTheme.of(context).primaryColor.withValues(alpha: 0.85);
    } else if (_hover) {
      bg = MacosColors.white.withValues(alpha: 0.06);
    }

    final Color fg;
    if (widget.eligible || widget.activeDrop) {
      fg = MacosColors.systemGreenColor;
    } else if (widget.selected) {
      fg = MacosColors.white;
    } else {
      fg = MacosColors.systemGrayColor;
    }

    final row = Tappable(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      onTap: widget.onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 1),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            MacosIcon(widget.icon, size: 16, color: fg),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                widget.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: typography.body.copyWith(
                  color: widget.selected && !widget.eligible
                      ? MacosColors.white
                      : null,
                  fontWeight: widget.eligible
                      ? FontWeight.w600
                      : FontWeight.normal,
                ),
              ),
            ),
          ],
        ),
      ),
    );

    return AnimatedOpacity(
      duration: const Duration(milliseconds: 120),
      opacity: widget.dimmed ? 0.4 : 1.0,
      child: row,
    );
  }
}
