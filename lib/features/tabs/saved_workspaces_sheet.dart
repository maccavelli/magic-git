import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/providers/app_providers.dart';
import '../../core/storage/saved_workspace_set.dart';
import '../common/actions.dart';
import '../common/prompt_text_sheet.dart';
import '../common/sized_sheet.dart';
import '../common/tool_icon_button.dart';
import 'saved_workspace_actions.dart';
import 'tabs_controller.dart';

class SavedWorkspacesSheet extends ConsumerStatefulWidget {
  const SavedWorkspacesSheet({super.key});

  @override
  ConsumerState<SavedWorkspacesSheet> createState() =>
      _SavedWorkspacesSheetState();
}

class _SavedWorkspacesSheetState extends ConsumerState<SavedWorkspacesSheet> {
  String? _status;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    final sets = ref.watch(savedWorkspaceSetsProvider);
    final tabs = TabsController.current;
    final active = tabs?.active;
    final activeCanAlias =
        active != null && tabs?.repositoryIdentityFor(active) != null;
    return SizedSheet(
      width: kSheetWidth,
      height: (MediaQuery.sizeOf(context).height - 96).clamp(320.0, 500.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 12, 10),
            child: Row(
              children: [
                Text('Saved Workspaces', style: typography.title2),
                const Spacer(),
                ToolIconButton(
                  icon: CupertinoIcons.pencil,
                  tooltip: activeCanAlias
                      ? 'Rename active tab'
                      : 'Only saved repositories can have aliases',
                  onPressed: activeCanAlias && !_busy
                      ? () => _renameActive(tabs!)
                      : null,
                ),
                const SizedBox(width: 4),
                ToolIconButton(
                  icon: CupertinoIcons.plus,
                  tooltip: 'Save current tabs as workspace',
                  onPressed: tabs != null && !_busy
                      ? () => _saveCurrent(tabs)
                      : null,
                ),
                const SizedBox(width: 4),
                ToolIconButton(
                  icon: CupertinoIcons.xmark,
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(18, 0, 18, 10),
            child: SheetDescription(
              'Save the ordered set of open repositories, then restore every '
              'available member without closing successful tabs when another '
              'member fails.',
            ),
          ),
          Container(height: 1, color: MacosColors.separatorColor),
          Expanded(
            child: sets.when(
              loading: () => const Center(child: ProgressCircle()),
              error: (error, _) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('Could not load saved workspaces: $error'),
                ),
              ),
              data: (items) => items.isEmpty
                  ? Center(
                      child: Text(
                        'No saved workspaces yet.',
                        style: typography.body.copyWith(
                          color: MacosColors.systemGrayColor,
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: items.length,
                      separatorBuilder: (_, _) => Container(
                        height: 1,
                        color: MacosColors.separatorColor,
                      ),
                      itemBuilder: (context, index) =>
                          _workspaceRow(items[index]),
                    ),
            ),
          ),
          if (_status != null) ...[
            Container(height: 1, color: MacosColors.separatorColor),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 10, 18, 12),
              child: Text(
                _status!,
                style: typography.caption1.copyWith(
                  color: MacosColors.systemGrayColor,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _workspaceRow(SavedWorkspaceSet set) {
    final typography = MacosTheme.of(context).typography;
    final aliases = [
      for (final repository in set.repositories)
        repository.tabAlias ?? _basename(repository.repoPath),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 10, 10, 10),
      child: Row(
        children: [
          const MacosIcon(CupertinoIcons.rectangle_stack, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(set.displayName, style: typography.body),
                const SizedBox(height: 2),
                Text(
                  aliases.join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: typography.caption1.copyWith(
                    color: MacosColors.systemGrayColor,
                  ),
                ),
              ],
            ),
          ),
          ToolIconButton(
            icon: CupertinoIcons.play,
            tooltip: 'Open ${set.displayName}',
            onPressed: _busy ? null : () => _open(set),
          ),
          ToolIconButton(
            icon: CupertinoIcons.trash,
            tooltip: 'Delete ${set.displayName}',
            color: MacosColors.systemRedColor,
            onPressed: _busy ? null : () => _delete(set),
          ),
        ],
      ),
    );
  }

  Future<void> _saveCurrent(TabsController tabs) async {
    final name = await promptText(
      context,
      'Save Workspace',
      placeholder: 'Workspace name',
      confirmLabel: 'Save',
    );
    if (name == null || !mounted) return;
    final repositories = <SavedWorkspaceRepositoryRef>[];
    var activeIndex = 0;
    for (final tab in tabs.tabs) {
      final identity = tabs.repositoryIdentityFor(tab);
      if (identity == null) continue;
      if (tab.id == tabs.activeId) activeIndex = repositories.length;
      final repoPath = tab.repoPath;
      final prefs =
          repoPath == null ||
              !tab.container.exists(repositoryWorkspacePrefsProvider(repoPath))
          ? null
          : tab.container
                .read(repositoryWorkspacePrefsProvider(repoPath))
                .value;
      repositories.add(
        SavedWorkspaceRepositoryRef(
          kind: identity.kind,
          savedId: identity.savedId,
          repoPath: identity.repoPath,
          tabAlias: tabs.aliasFor(tab),
          layoutPresetName: prefs?.preset.name,
        ),
      );
    }
    if (repositories.isEmpty) {
      setState(() => _status = 'No saved repositories are open.');
      return;
    }
    await _run(() async {
      await ref
          .read(savedWorkspaceStoreProvider)
          .save(
            SavedWorkspaceSet(
              id: DateTime.now().microsecondsSinceEpoch.toString(),
              displayName: name,
              repositories: repositories,
              activeIndex: activeIndex,
            ),
          );
      ref.invalidate(savedWorkspaceSetsProvider);
      _status = 'Saved "$name" with ${repositories.length} repositories.';
    });
  }

  Future<void> _renameActive(TabsController tabs) async {
    final tab = tabs.active;
    if (tab == null || tabs.repositoryIdentityFor(tab) == null) return;
    final alias = await promptText(
      context,
      'Rename Tab',
      initial: tabs.aliasFor(tab) ?? '',
      placeholder: _basename(tab.repoPath ?? ''),
      confirmLabel: 'Rename',
      // A confirmed blank means "clear the alias" — distinct from Cancel.
      allowEmpty: true,
    );
    if (alias == null || !mounted) return;
    await _run(() async {
      await tabs.setAlias(tab, alias);
      _status = alias.trim().isEmpty
          ? 'Tab alias cleared.'
          : 'Tab renamed to "${alias.trim()}".';
    });
  }

  Future<void> _open(SavedWorkspaceSet set) async {
    await _run(() async {
      final report = await openSavedWorkspaceSet(context, ref, set);
      final success = report.openedCount + report.focusedCount;
      if (!report.hasFailures) {
        _status = 'Opened ${set.displayName} ($success repositories).';
        return;
      }
      final details = [
        for (final failure in report.failures)
          '${failure.repository.tabAlias ?? _basename(failure.repository.repoPath)}: '
              '${failure.reason}',
      ];
      _status =
          '$success opened; ${report.failures.length} failed. '
          '${details.join(' ')}';
    });
  }

  Future<void> _delete(SavedWorkspaceSet set) async {
    final confirmed = await confirmAction(
      context,
      title: 'Delete saved workspace?',
      message: 'Delete "${set.displayName}"? Open tabs are not affected.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    await _run(() async {
      await ref.read(savedWorkspaceStoreProvider).delete(set.id);
      ref.invalidate(savedWorkspaceSetsProvider);
      _status = 'Deleted "${set.displayName}".';
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      if (mounted) _status = 'Workspace action failed: $error';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

String _basename(String path) {
  final parts = path.split('/').where((part) => part.isNotEmpty).toList();
  return parts.isEmpty ? path : parts.last;
}
