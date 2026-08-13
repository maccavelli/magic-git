import 'package:flutter/widgets.dart';

import '../../core/settings/repository_workspace_prefs.dart';
import 'adaptive_workspace_layout.dart';
import 'async_views.dart';
import 'repository_workspace_models.dart';
import 'workspace_appearance.dart';
import 'workspace_focus_order.dart';

class WorkspacePreferencesScope extends InheritedWidget {
  final RepositoryWorkspacePrefs preferences;
  final ValueChanged<RepositoryWorkspacePrefs>? onChanged;
  final bool optionsEnabled;

  const WorkspacePreferencesScope({
    super.key,
    required this.preferences,
    required this.onChanged,
    required this.optionsEnabled,
    required super.child,
  });

  static WorkspacePreferencesScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<WorkspacePreferencesScope>();

  @override
  bool updateShouldNotify(WorkspacePreferencesScope oldWidget) =>
      preferences != oldWidget.preferences ||
      onChanged != oldWidget.onChanged ||
      optionsEnabled != oldWidget.optionsEnabled;
}

/// Feature-neutral frame for repository-centered workspaces.
class RepositoryWorkspaceScaffold extends StatelessWidget {
  final Widget repositoryContext;
  final Widget? navigator;
  final Widget canvas;
  final Widget? inspector;
  final Widget? taskDock;
  final bool loading;
  final Object? error;
  final VoidCallback? onRetry;
  final CompactWorkspacePage activePage;
  final bool inspectorVisible;
  final bool taskDockFocused;
  final RepositoryWorkspacePrefs preferences;
  final ValueChanged<RepositoryWorkspacePrefs>? onPreferencesChanged;
  final bool workspaceOptionsEnabled;

  const RepositoryWorkspaceScaffold({
    super.key,
    required this.repositoryContext,
    this.navigator,
    required this.canvas,
    this.inspector,
    this.taskDock,
    this.loading = false,
    this.error,
    this.onRetry,
    this.activePage = CompactWorkspacePage.canvas,
    this.inspectorVisible = false,
    this.taskDockFocused = false,
    this.preferences = const RepositoryWorkspacePrefs(),
    this.onPreferencesChanged,
    this.workspaceOptionsEnabled = false,
  });

  @override
  Widget build(BuildContext context) {
    final Object? failure = error;
    final Widget content;
    if (failure != null) {
      content = Center(child: SectionError(failure));
    } else if (loading) {
      content = const WorkspaceLoading(label: 'Loading repository');
    } else {
      content = AdaptiveWorkspaceLayout(
        navigator: navigator,
        canvas: canvas,
        inspector: inspector,
        taskDock: taskDock,
        compactPage: activePage,
        inspectorVisible: inspectorVisible,
        taskDockFocused: taskDockFocused,
        preferences: preferences,
        onPreferencesChanged: onPreferencesChanged,
      );
    }
    return WorkspaceAppearanceBoundary(
      child: WorkspacePreferencesScope(
        preferences: preferences,
        onChanged: onPreferencesChanged,
        optionsEnabled: workspaceOptionsEnabled,
        child: FocusTraversalGroup(
          policy: OrderedTraversalPolicy(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              WorkspaceFocusRegion(
                role: WorkspacePaneRole.repositoryContext,
                child: repositoryContext,
              ),
              Expanded(child: content),
            ],
          ),
        ),
      ),
    );
  }
}
