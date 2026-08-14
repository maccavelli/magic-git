import 'package:flutter/cupertino.dart';

import '../../core/settings/repository_workspace_prefs.dart';
import 'context_menu.dart';
import 'repository_workspace_models.dart';
import 'repository_workspace_scaffold.dart';
import 'tool_icon_button.dart';
import 'workspace_focus_order.dart';

class WorkspaceViewOptionsButton extends StatefulWidget {
  const WorkspaceViewOptionsButton({super.key});

  @override
  State<WorkspaceViewOptionsButton> createState() =>
      _WorkspaceViewOptionsButtonState();
}

class _WorkspaceViewOptionsButtonState
    extends State<WorkspaceViewOptionsButton> {
  final ContextMenuOverlay _menu = ContextMenuOverlay();
  final GlobalKey _anchorKey = GlobalKey();

  @override
  void dispose() {
    _menu.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scope = WorkspacePreferencesScope.maybeOf(context);
    if (scope == null || !scope.optionsEnabled || scope.onChanged == null) {
      return const SizedBox.shrink();
    }
    return ToolIconButton(
      key: _anchorKey,
      icon: CupertinoIcons.rectangle_3_offgrid,
      tooltip: 'Workspace view options',
      onPressed: () => _show(context, scope),
    );
  }

  void _show(BuildContext context, WorkspacePreferencesScope scope) {
    final anchor = _anchorKey.currentContext?.findRenderObject();
    if (anchor is! RenderBox) return;
    final preferences = scope.preferences;
    final position = anchor.localToGlobal(Offset(0, anchor.size.height));
    _menu.show(context, position, [
      ContextMenuItem(
        icon: preferences.showToolbarLabels
            ? CupertinoIcons.check_mark
            : CupertinoIcons.textformat,
        label: 'Show secondary action labels',
        onTap: () => scope.onChanged!(
          preferences.copyWith(
            showToolbarLabels: !preferences.showToolbarLabels,
          ),
        ),
      ),
      for (final slot in WorkspaceToolbarSlot.values)
        ContextMenuItem(
          icon: preferences.visibleToolbarSlots.contains(slot)
              ? CupertinoIcons.check_mark
              : CupertinoIcons.square,
          label: 'Show ${slot.label}',
          onTap: () {
            final next = Set<WorkspaceToolbarSlot>.from(
              preferences.visibleToolbarSlots,
            );
            if (!next.remove(slot)) next.add(slot);
            scope.onChanged!(preferences.copyWith(visibleToolbarSlots: next));
          },
        ),
      const ContextMenuDivider(),
      for (final preset in WorkspacePreset.values)
        ContextMenuItem(
          icon: preset == preferences.preset
              ? CupertinoIcons.check_mark
              : _presetIcon(preset),
          label: '${preset.label} preset',
          onTap: () => _applyPreset(scope, preferences, preset),
        ),
    ], width: 230);
  }

  void _applyPreset(
    WorkspacePreferencesScope scope,
    RepositoryWorkspacePrefs preferences,
    WorkspacePreset preset,
  ) {
    scope.onChanged!(applyWorkspacePreset(preferences, preset));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final requested = WorkspacePaneFocusRegistry.instance.request(
        _focusRole(preset),
      );
      if (!requested) {
        WorkspacePaneFocusRegistry.instance.request(WorkspacePaneRole.canvas);
      }
    });
  }

  IconData _presetIcon(WorkspacePreset preset) => switch (preset) {
    WorkspacePreset.review => CupertinoIcons.doc_text_search,
    WorkspacePreset.commit => CupertinoIcons.check_mark_circled,
    WorkspacePreset.investigate => CupertinoIcons.search,
    WorkspacePreset.minimal => CupertinoIcons.rectangle,
  };

  WorkspacePaneRole _focusRole(WorkspacePreset preset) => switch (preset) {
    WorkspacePreset.review => WorkspacePaneRole.canvas,
    WorkspacePreset.commit => WorkspacePaneRole.taskDock,
    WorkspacePreset.investigate => WorkspacePaneRole.inspector,
    WorkspacePreset.minimal => WorkspacePaneRole.canvas,
  };
}
