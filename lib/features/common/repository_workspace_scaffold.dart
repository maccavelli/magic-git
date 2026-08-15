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

/// Marks a subtree as being mounted *inside* another repository workspace —
/// today, a worktree tab, whose own chrome already names the checkout.
///
/// A nested workspace screen must not draw a second context bar under the
/// first: two bars stacked a few pixels apart, the inner one describing the
/// worktree the outer one just named. The suppression lives here rather than
/// as a flag threaded through every screen, because [RepositoryWorkspaceScaffold]
/// is the single place all six of them render their bar.
class NestedWorkspaceScope extends InheritedWidget {
  const NestedWorkspaceScope({super.key, required super.child});

  static bool isNested(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<NestedWorkspaceScope>() !=
      null;

  @override
  bool updateShouldNotify(NestedWorkspaceScope oldWidget) => false;
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
    // Nested inside another workspace (a worktree tab): that outer chrome has
    // already named the repository, so this screen contributes content only.
    final nested = NestedWorkspaceScope.isNested(context);
    return WorkspaceAppearanceBoundary(
      child: WorkspacePreferencesScope(
        preferences: preferences,
        onChanged: onPreferencesChanged,
        optionsEnabled: workspaceOptionsEnabled,
        child: FocusTraversalGroup(
          policy: OrderedTraversalPolicy(),
          child: nested
              ? content
              : Column(
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
