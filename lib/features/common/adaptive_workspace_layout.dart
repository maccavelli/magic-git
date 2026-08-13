import 'package:flutter/widgets.dart';

import '../../core/settings/repository_workspace_prefs.dart';
import 'repository_workspace_models.dart';
import 'resizable_master_detail.dart';
import 'workspace_focus_order.dart';

enum CompactWorkspacePage { navigator, canvas }

enum WorkspaceTaskDockPresentation { hidden, compact, full }

@immutable
class AdaptiveWorkspaceArrangement {
  final WorkspaceSizeClass sizeClass;
  final bool navigatorAndCanvas;
  final bool inspectorOverlay;
  final bool pinnedInspector;
  final WorkspaceTaskDockPresentation taskDock;

  const AdaptiveWorkspaceArrangement({
    required this.sizeClass,
    required this.navigatorAndCanvas,
    required this.inspectorOverlay,
    required this.pinnedInspector,
    required this.taskDock,
  });
}

AdaptiveWorkspaceArrangement resolveAdaptiveWorkspaceArrangement({
  required double width,
  required RepositoryWorkspacePrefs preferences,
  required bool hasInspector,
  required bool inspectorVisible,
  required bool taskDockFocused,
}) {
  final sizeClass = WorkspaceSizeClass.fromWidth(width);
  final inspectorRequested =
      hasInspector &&
      !preferences.inspectorCollapsed &&
      (inspectorVisible || preferences.inspectorPinned);
  return switch (sizeClass) {
    WorkspaceSizeClass.compact => AdaptiveWorkspaceArrangement(
      sizeClass: sizeClass,
      navigatorAndCanvas: false,
      inspectorOverlay: inspectorRequested,
      pinnedInspector: false,
      taskDock: taskDockFocused
          ? WorkspaceTaskDockPresentation.compact
          : WorkspaceTaskDockPresentation.hidden,
    ),
    WorkspaceSizeClass.standard => AdaptiveWorkspaceArrangement(
      sizeClass: sizeClass,
      navigatorAndCanvas: true,
      inspectorOverlay: inspectorRequested,
      pinnedInspector: false,
      taskDock: preferences.taskDockCollapsed
          ? WorkspaceTaskDockPresentation.hidden
          : WorkspaceTaskDockPresentation.compact,
    ),
    WorkspaceSizeClass.wide => AdaptiveWorkspaceArrangement(
      sizeClass: sizeClass,
      navigatorAndCanvas: true,
      inspectorOverlay: inspectorRequested && !preferences.inspectorPinned,
      pinnedInspector: inspectorRequested && preferences.inspectorPinned,
      taskDock: preferences.taskDockCollapsed
          ? WorkspaceTaskDockPresentation.hidden
          : WorkspaceTaskDockPresentation.full,
    ),
  };
}

/// Adaptive pane engine shared by repository-centered screens.
class AdaptiveWorkspaceLayout extends StatefulWidget {
  final Widget? navigator;
  final Widget canvas;
  final Widget? inspector;
  final Widget? taskDock;
  final CompactWorkspacePage compactPage;
  final bool inspectorVisible;
  final bool taskDockFocused;
  final RepositoryWorkspacePrefs preferences;
  final ValueChanged<RepositoryWorkspacePrefs>? onPreferencesChanged;

  const AdaptiveWorkspaceLayout({
    super.key,
    this.navigator,
    required this.canvas,
    this.inspector,
    this.taskDock,
    this.compactPage = CompactWorkspacePage.canvas,
    this.inspectorVisible = false,
    this.taskDockFocused = false,
    this.preferences = const RepositoryWorkspacePrefs(),
    this.onPreferencesChanged,
  });

  @override
  State<AdaptiveWorkspaceLayout> createState() =>
      _AdaptiveWorkspaceLayoutState();
}

class _AdaptiveWorkspaceLayoutState extends State<AdaptiveWorkspaceLayout> {
  late double _navigatorWidth = widget.preferences.navigatorWidth;
  late double _inspectorWidth = widget.preferences.inspectorWidth;
  late double _taskDockHeight = widget.preferences.taskDockHeight;

  @override
  void didUpdateWidget(AdaptiveWorkspaceLayout oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.preferences.navigatorWidth !=
        widget.preferences.navigatorWidth) {
      _navigatorWidth = widget.preferences.navigatorWidth;
    }
    if (oldWidget.preferences.inspectorWidth !=
        widget.preferences.inspectorWidth) {
      _inspectorWidth = widget.preferences.inspectorWidth;
    }
    if (oldWidget.preferences.taskDockHeight !=
        widget.preferences.taskDockHeight) {
      _taskDockHeight = widget.preferences.taskDockHeight;
    }
  }

  void _updatePrefs(RepositoryWorkspacePrefs next) {
    widget.onPreferencesChanged?.call(next.normalized);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final arrangement = resolveAdaptiveWorkspaceArrangement(
          width: constraints.maxWidth,
          preferences: widget.preferences,
          hasInspector: widget.inspector != null,
          inspectorVisible: widget.inspectorVisible,
          taskDockFocused: widget.taskDockFocused,
        );
        Widget main = _mainFor(arrangement);
        final dock = widget.taskDock;
        if (dock != null &&
            arrangement.taskDock != WorkspaceTaskDockPresentation.hidden) {
          final mainWithoutDock = main;
          final compact =
              arrangement.taskDock == WorkspaceTaskDockPresentation.compact;
          final dockHeight = compact
              ? _taskDockHeight.clamp(120, 220).toDouble()
              : _taskDockHeight;
          main = LayoutBuilder(
            builder: (context, inner) => ResizablePanePair(
              axis: Axis.vertical,
              leading: mainWithoutDock,
              trailing: WorkspaceFocusRegion(
                role: WorkspacePaneRole.taskDock,
                child: dock,
              ),
              extent: inner.maxHeight - dockHeight - 1,
              minExtent: 160,
              maxExtent: inner.maxHeight - 121,
              trailingFloor: 120,
              defaultExtent:
                  inner.maxHeight -
                  RepositoryWorkspacePrefs.defaultTaskDockHeight -
                  1,
              semanticLabel: 'Resize task dock',
              onCommit: (mainHeight) {
                final nextHeight = inner.maxHeight - mainHeight - 1;
                setState(() => _taskDockHeight = nextHeight);
                _updatePrefs(
                  widget.preferences.copyWith(taskDockHeight: nextHeight),
                );
              },
            ),
          );
        }
        if (arrangement.inspectorOverlay && widget.inspector != null) {
          main = Stack(
            children: [
              Positioned.fill(child: main),
              Positioned(
                top: 0,
                right: 0,
                bottom: 0,
                width: _inspectorWidth.clamp(
                  RepositoryWorkspacePrefs.minInspectorWidth,
                  constraints.maxWidth,
                ),
                child: WorkspaceFocusRegion(
                  role: WorkspacePaneRole.inspector,
                  child: widget.inspector!,
                ),
              ),
            ],
          );
        }
        return main;
      },
    );
  }

  Widget _mainFor(AdaptiveWorkspaceArrangement arrangement) {
    final navigator = widget.navigator;
    final canvas = WorkspaceFocusRegion(
      role: WorkspacePaneRole.canvas,
      child: widget.canvas,
    );
    if (navigator == null) return canvas;
    final navigatorRegion = WorkspaceFocusRegion(
      role: WorkspacePaneRole.navigator,
      child: navigator,
    );
    if (!arrangement.navigatorAndCanvas) {
      if (widget.preferences.navigatorCollapsed) return canvas;
      return widget.compactPage == CompactWorkspacePage.navigator
          ? navigatorRegion
          : canvas;
    }

    Widget body = ResizablePanePair(
      leading: navigatorRegion,
      trailing: canvas,
      extent: _navigatorWidth,
      minExtent: RepositoryWorkspacePrefs.minNavigatorWidth,
      maxExtent: RepositoryWorkspacePrefs.maxNavigatorWidth,
      trailingFloor: 320,
      defaultExtent: RepositoryWorkspacePrefs.defaultNavigatorWidth,
      collapsed: widget.preferences.navigatorCollapsed,
      semanticLabel: 'Resize repository navigator',
      onCommit: (width) {
        setState(() => _navigatorWidth = width);
        _updatePrefs(widget.preferences.copyWith(navigatorWidth: width));
      },
    );
    if (arrangement.pinnedInspector && widget.inspector != null) {
      final main = body;
      body = LayoutBuilder(
        builder: (context, constraints) => ResizablePanePair(
          leading: main,
          trailing: WorkspaceFocusRegion(
            role: WorkspacePaneRole.inspector,
            child: widget.inspector!,
          ),
          extent: constraints.maxWidth - _inspectorWidth - 1,
          minExtent: 320,
          maxExtent:
              constraints.maxWidth -
              RepositoryWorkspacePrefs.minInspectorWidth -
              1,
          trailingFloor: RepositoryWorkspacePrefs.minInspectorWidth,
          defaultExtent:
              constraints.maxWidth -
              RepositoryWorkspacePrefs.defaultInspectorWidth -
              1,
          semanticLabel: 'Resize repository inspector',
          onCommit: (mainWidth) {
            final width = constraints.maxWidth - mainWidth - 1;
            setState(() => _inspectorWidth = width);
            _updatePrefs(widget.preferences.copyWith(inspectorWidth: width));
          },
        ),
      );
    }
    return body;
  }
}
