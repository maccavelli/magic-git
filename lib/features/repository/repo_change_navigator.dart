import 'package:flutter/cupertino.dart' hide OverlayVisibilityMode;
import 'package:flutter/services.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/settings/repository_workspace_prefs.dart';
import '../common/field_styles.dart';
import '../common/inline_action_button.dart';
import '../common/tool_icon_button.dart';
import 'repo_change_filter.dart';
import 'repo_change_model.dart';

class RepoChangeNavigator extends StatelessWidget {
  final RepositoryNavigatorMode mode;
  final ValueChanged<RepositoryNavigatorMode> onModeChanged;
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
  final Widget files;

  const RepoChangeNavigator({
    super.key,
    required this.mode,
    required this.onModeChanged,
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
    required this.files,
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
              CupertinoSlidingSegmentedControl<RepositoryNavigatorMode>(
                groupValue: mode,
                children: const {
                  RepositoryNavigatorMode.changes: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12),
                    child: Text('Changes'),
                  ),
                  RepositoryNavigatorMode.files: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12),
                    child: Text('Files'),
                  ),
                },
                onValueChanged: (next) {
                  if (next != null) onModeChanged(next);
                },
              ),
              if (mode == RepositoryNavigatorMode.changes) ...[
                const SizedBox(height: 7),
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
                      CupertinoIcons.exclamationmark_triangle,
                      'Conflicts',
                    ),
                    _statusButton(
                      RepoChangeSection.staged,
                      CupertinoIcons.check_mark_circled,
                      'Staged',
                    ),
                    _statusButton(
                      RepoChangeSection.unstaged,
                      CupertinoIcons.pencil,
                      'Changes',
                    ),
                    _statusButton(
                      RepoChangeSection.untracked,
                      CupertinoIcons.question_circle,
                      'Untracked',
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
          child: mode == RepositoryNavigatorMode.files
              ? files
              : visibleCount == 0 && totalCount > 0
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
  ) => ToolIconButton(
    icon: icon,
    tooltip: 'Filter $label',
    size: 14,
    color: filter.statuses.contains(section)
        ? MacosColors.systemBlueColor
        : MacosColors.systemGrayColor,
    onPressed: () => _toggleStatus(section),
  );
}
