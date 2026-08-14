import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'tappable.dart';

/// **Canonical list-section collapse for the whole app.** Any tab whose list
/// column is split into named sections (Forge: Issues / Pull Requests / …;
/// Branches: Local / Remote / Tags / …) uses this one store plus
/// [CollapsibleSectionHeader], so minimize/expand behaves and reads the same
/// everywhere.
///
/// The set holds the names of collapsed sections. Names must be globally
/// unique across tabs — the store is one flat namespace — so callers prefix
/// them (`'branches.local'`, forge's short `'issues'`). Global, not per repo:
/// minimizing a section is a statement about that section's usefulness, not
/// about one repository. Persisted as a string list; unknown names are carried
/// untouched, so renaming or removing a section never scrambles the rest.
class CollapsedSections extends Notifier<Set<String>> {
  static const _key = 'collapsedSections';

  @override
  Set<String> build() {
    _load();
    return const {};
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getStringList(_key);
      if (stored != null && stored.isNotEmpty) state = stored.toSet();
    } catch (_) {
      // No stored state (or no prefs backend, e.g. a bare test harness):
      // the in-memory default stands.
    }
  }

  bool isCollapsed(String section) => state.contains(section);

  Future<void> toggle(String section) async {
    final next = Set<String>.from(state);
    next.contains(section) ? next.remove(section) : next.add(section);
    state = next;
    // Best-effort: a persistence failure must never break the toggle.
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_key, next.toList()..sort());
    } catch (_) {}
  }
}

final collapsedSectionsProvider =
    NotifierProvider<CollapsedSections, Set<String>>(CollapsedSections.new);

/// The disclosure chevron every collapsible header shows to the left of its
/// title — one place so the size/colour/glyph stay identical across tabs.
class CollapseChevron extends StatelessWidget {
  final bool collapsed;

  const CollapseChevron(this.collapsed, {super.key});

  @override
  Widget build(BuildContext context) => MacosIcon(
    collapsed ? CupertinoIcons.chevron_right : CupertinoIcons.chevron_down,
    size: 10,
    color: MacosColors.systemGrayColor,
  );
}

/// **The one list-section header idiom.** A bold caption title, optionally a
/// leading disclosure chevron (when [collapsed]/[onToggle] are supplied) and a
/// leading [leading] glyph, an optional grey [count] caption, then a
/// right-aligned cluster of [trailing] action buttons.
///
/// When [onToggle] is non-null the title cluster becomes a click target that
/// toggles collapse; the caller owns the collapsed state (via
/// [collapsedSectionsProvider]) and hides the section body itself. When it is
/// null the header renders as a plain, non-collapsible caption — the shape a
/// header keeps when a section is always shown.
class CollapsibleSectionHeader extends StatelessWidget {
  final String title;

  /// Optional grey count caption after the title (`"30 of 974"`), so a section
  /// whose fetch is capped says so instead of silently truncating.
  final String? count;

  /// Optional grey note after [count], for a standing fact about the section
  /// rather than a number — e.g. `"view only"` where the rows are inert. Kept
  /// separate from [count] so a count assertion stays a count assertion.
  final String? caption;

  /// Non-null → the title becomes a disclosure toggle. [collapsed] drives the
  /// chevron glyph; [onToggle] flips the stored state.
  final bool? collapsed;
  final VoidCallback? onToggle;

  /// A glyph shown between the chevron and the title (e.g. the Pinned star).
  final Widget? leading;

  /// Right-aligned action buttons (add / refresh / push …).
  final List<Widget> trailing;

  final EdgeInsets padding;

  const CollapsibleSectionHeader(
    this.title, {
    super.key,
    this.count,
    this.caption,
    this.collapsed,
    this.onToggle,
    this.leading,
    this.trailing = const [],
    this.padding = const EdgeInsets.fromLTRB(16, 8, 8, 4),
  });

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    final titleCluster = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (collapsed != null) ...[
          CollapseChevron(collapsed!),
          const SizedBox(width: 4),
        ],
        if (leading != null) ...[leading!, const SizedBox(width: 6)],
        Text(
          title,
          style: typography.caption1.copyWith(fontWeight: FontWeight.bold),
        ),
        if (count != null)
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: Text(
              count!,
              style: typography.caption1.copyWith(
                color: MacosColors.systemGrayColor,
              ),
            ),
          ),
        if (caption != null)
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: Text(
              caption!,
              style: typography.caption1.copyWith(
                color: MacosColors.systemGrayColor,
              ),
            ),
          ),
      ],
    );
    return Padding(
      padding: padding,
      child: Row(
        children: [
          if (onToggle != null)
            Tappable(
              onTap: onToggle,
              behavior: HitTestBehavior.opaque,
              child: titleCluster,
            )
          else
            titleCluster,
          const Spacer(),
          ...trailing,
        ],
      ),
    );
  }
}
