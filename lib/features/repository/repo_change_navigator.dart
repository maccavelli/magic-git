import 'package:flutter/cupertino.dart' hide OverlayVisibilityMode;
import 'package:flutter/services.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/settings/repository_workspace_prefs.dart';
import '../common/field_styles.dart';
import '../common/inline_action_button.dart';
import '../common/tappable.dart';
import '../common/tool_icon_button.dart';
import 'repo_change_filter.dart';
import 'repo_change_model.dart';

class RepoChangeNavigator extends StatelessWidget {
  final TextEditingController filterController;
  final RepoChangeFilter filter;
  final ValueChanged<RepoChangeFilter> onFilterChanged;
  final int visibleCount;
  final int totalCount;
  final int hiddenSelectionCount;
  final VoidCallback onRevealSelection;
  final VoidCallback onClearSelection;
  final int selectedCount;
  final VoidCallback? onReviewSelected;
  final VoidCallback? onReviewAllVisible;
  final Widget changes;

  const RepoChangeNavigator({
    super.key,
    required this.filterController,
    required this.filter,
    required this.onFilterChanged,
    required this.visibleCount,
    required this.totalCount,
    required this.hiddenSelectionCount,
    required this.onRevealSelection,
    required this.onClearSelection,
    this.selectedCount = 0,
    this.onReviewSelected,
    this.onReviewAllVisible,
    required this.changes,
  });

  KeyEventResult _onFilterKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape ||
        filterController.text.isEmpty) {
      return KeyEventResult.ignored;
    }
    filterController.clear();
    onFilterChanged(filter.copyWith(query: ''));
    return KeyEventResult.handled;
  }

  void _toggleStatus(RepoChangeSection section) {
    final next = {...filter.statuses};
    next.contains(section) ? next.remove(section) : next.add(section);
    onFilterChanged(filter.copyWith(statuses: next));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Focus(
                onKeyEvent: _onFilterKey,
                child: MacosTextField(
                  controller: filterController,
                  placeholder: 'Filter changed paths',
                  placeholderStyle: kAppPlaceholderStyle,
                  decoration: kAppTextFieldDecoration,
                  focusedDecoration: kAppTextFieldFocusedDecoration,
                  prefix: const MacosIcon(CupertinoIcons.search, size: 14),
                  clearButtonMode: OverlayVisibilityMode.editing,
                  onChanged: (query) =>
                      onFilterChanged(filter.copyWith(query: query)),
                ),
              ),
              const SizedBox(height: 5),
              Row(
                children: [
                  _statusButton(
                    RepoChangeSection.conflict,
                    CupertinoIcons.exclamationmark_triangle_fill,
                    'Conflicts',
                    MacosColors.systemRedColor,
                  ),
                  _statusButton(
                    RepoChangeSection.staged,
                    CupertinoIcons.checkmark_alt_circle_fill,
                    'Staged',
                    MacosColors.systemGreenColor,
                  ),
                  _statusButton(
                    RepoChangeSection.unstaged,
                    CupertinoIcons.pencil_circle_fill,
                    'Unstaged',
                    MacosColors.systemOrangeColor,
                  ),
                  _statusButton(
                    RepoChangeSection.untracked,
                    CupertinoIcons.plus_square_fill,
                    'Untracked',
                    MacosColors.systemTealColor,
                  ),
                  const Spacer(),
                  Text(
                    '$visibleCount of $totalCount',
                    style: MacosTheme.of(context).typography.caption1,
                  ),
                  const SizedBox(width: 4),
                  if (filter.active)
                    ToolIconButton(
                      icon: CupertinoIcons.clear_circled,
                      tooltip: 'Clear filters',
                      size: 14,
                      onPressed: () {
                        filterController.clear();
                        onFilterChanged(
                          RepoChangeFilter(grouping: filter.grouping),
                        );
                      },
                    ),
                  MacosPulldownButton(
                    icon: CupertinoIcons.line_horizontal_3_decrease,
                    items: [
                      MacosPulldownMenuItem(
                        title: const Text('Group by status'),
                        onTap: () => onFilterChanged(
                          filter.copyWith(
                            grouping: RepositoryChangeGrouping.status,
                          ),
                        ),
                      ),
                      MacosPulldownMenuItem(
                        title: const Text('Group by directory'),
                        onTap: () => onFilterChanged(
                          filter.copyWith(
                            grouping: RepositoryChangeGrouping.directory,
                          ),
                        ),
                      ),
                      const MacosPulldownMenuDivider(),
                      MacosPulldownMenuItem(
                        title: Text(
                          filter.includeReviewed
                              ? 'Hide reviewed paths'
                              : 'Include reviewed paths',
                        ),
                        onTap: () => onFilterChanged(
                          filter.copyWith(
                            includeReviewed: !filter.includeReviewed,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 5),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 6,
                runSpacing: 3,
                children: [
                  if (selectedCount > 1)
                    InlineActionButton(
                      label: 'Review selected ($selectedCount)',
                      icon: CupertinoIcons.rectangle_stack,
                      onPressed: onReviewSelected,
                    ),
                  InlineActionButton(
                    label: 'Review all visible',
                    icon: CupertinoIcons.eye,
                    onPressed: visibleCount == 0 ? null : onReviewAllVisible,
                  ),
                ],
              ),
            ],
          ),
        ),
        Container(height: 1, color: MacosColors.separatorColor),
        if (hiddenSelectionCount > 0)
          Container(
            color: MacosColors.systemYellowColor.withValues(alpha: 0.12),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '$hiddenSelectionCount selected item'
                    '${hiddenSelectionCount == 1 ? ' is' : 's are'} hidden '
                    'by filters',
                    style: MacosTheme.of(context).typography.caption1,
                  ),
                ),
                InlineActionButton(
                  label: 'Reveal',
                  icon: CupertinoIcons.eye,
                  onPressed: onRevealSelection,
                ),
                const SizedBox(width: 6),
                InlineActionButton(
                  label: 'Clear Selection',
                  icon: CupertinoIcons.xmark,
                  onPressed: onClearSelection,
                ),
              ],
            ),
          ),
        Expanded(
          child: visibleCount == 0 && totalCount > 0
              ? Center(
                  child: Text(
                    'No changed paths match the current filters.',
                    textAlign: TextAlign.center,
                    style: MacosTheme.of(context).typography.caption1.copyWith(
                      color: MacosColors.systemGrayColor,
                    ),
                  ),
                )
              : changes,
        ),
      ],
    );
  }

  Widget _statusButton(
    RepoChangeSection section,
    IconData icon,
    String label,
    Color color,
  ) => _StatusFilterToggle(
    icon: icon,
    label: label,
    color: color,
    selected: filter.statuses.contains(section),
    onPressed: () => _toggleStatus(section),
  );
}

/// Color-coded status filter. The old 14px gray outlines all read the same
/// and hid their meaning in a tooltip; these keep a distinct filled glyph
/// and the section's own color whether they are on or off.
class _StatusFilterToggle extends StatefulWidget {
  final IconData icon;
  final String label;
  final Color color;
  final bool selected;
  final VoidCallback onPressed;

  const _StatusFilterToggle({
    required this.icon,
    required this.label,
    required this.color,
    required this.selected,
    required this.onPressed,
  });

  @override
  State<_StatusFilterToggle> createState() => _StatusFilterToggleState();
}

class _StatusFilterToggleState extends State<_StatusFilterToggle> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final dark = MacosTheme.of(context).brightness.isDark;
    final selected = widget.selected;
    final color = widget.color;
    final fg = selected ? MacosColors.white : color;
    final fill = selected
        ? color.withValues(alpha: dark ? 0.88 : 0.92)
        : color.withValues(
            alpha: _hovered ? (dark ? 0.28 : 0.20) : (dark ? 0.16 : 0.12),
          );
    final border = color.withValues(
      alpha: selected ? 0.95 : (_hovered ? 0.55 : (dark ? 0.38 : 0.32)),
    );
    return MacosTooltip(
      message: selected
          ? 'Showing ${widget.label} — click to show all statuses'
          : 'Show only ${widget.label}',
      child: Tappable(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 110),
          curve: Curves.easeOut,
          margin: const EdgeInsets.only(right: 4),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color.alphaBlend(
                  MacosColors.white.withValues(alpha: dark ? 0.10 : 0.28),
                  fill,
                ),
                fill,
              ],
            ),
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: border, width: 0.5),
            boxShadow: [
              if (selected || _hovered)
                BoxShadow(
                  color: color.withValues(alpha: selected ? 0.28 : 0.14),
                  blurRadius: selected ? 4 : 2,
                  offset: const Offset(0, 0.5),
                ),
            ],
          ),
          child: MacosIcon(widget.icon, size: 15, color: fg),
        ),
      ),
    );
  }
}
