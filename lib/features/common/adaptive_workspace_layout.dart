import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/settings/repository_workspace_prefs.dart';
import 'inline_action_button.dart';
import 'repository_workspace_models.dart';
import 'resizable_master_detail.dart';
import 'workspace_focus_order.dart';

enum CompactWorkspacePage { navigator, canvas }

/// A page's side of compact navigation (MADR 0064 F1-A).
///
/// At the compact size class the layout shows one pane at a time. The page
/// owns [showCanvas] — a row tap sets it, as does plain Enter where the list
/// has no other use for Enter (Branches keeps Enter = check out); Back (the
/// back bar, Esc or ⌘[) clears it through [onShowNavigator] — and the
/// selection itself survives Back, as a collapsed split view does. The canvas
/// is shown only when [hasSelection] && [showCanvas]; arrow keys that move the
/// selection inside the list must leave [showCanvas] alone, so browsing the
/// list never flips the pane.
@immutable
class CompactWorkspaceNavigation {
  /// Names the list on the back bar: "‹ [navigatorLabel]".
  final String navigatorLabel;
  final bool hasSelection;
  final bool showCanvas;

  /// Back: clears the page's [showCanvas] so the list shows again. Named
  /// apart from the context bar's Back/Forward, which navigate the session's
  /// history and stay owned by the bar. The selection must be kept.
  final VoidCallback onShowNavigator;

  /// The list's own focus node, which receives focus on Back. When null the
  /// layout focuses a non-text node of its own inside the navigator region.
  final FocusNode? navigatorFocusNode;

  const CompactWorkspaceNavigation({
    required this.navigatorLabel,
    required this.hasSelection,
    required this.showCanvas,
    required this.onShowNavigator,
    this.navigatorFocusNode,
  });

  bool get wantsCanvas => hasSelection && showCanvas;
}

/// The back bar's button, for tests and for the pane-reachability contract.
const Key kWorkspaceCompactBackKey = Key('workspace-compact-back');

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

  /// When set, compact navigation is scaffold-owned (F1-A) and [compactPage]
  /// is ignored. Callers without it keep the legacy [compactPage] behaviour.
  final CompactWorkspaceNavigation? compactNavigation;
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
    this.compactNavigation,
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

  /// Holds focus for the canvas at the compact size class. It sits below the
  /// page's PanelShortcuts, so panel shortcuts keep working once the list —
  /// and the list's own focus node — has been unmounted.
  final FocusNode _compactCanvasFocus = FocusNode(
    debugLabel: 'workspace-compact-canvas',
    skipTraversal: true,
  );

  /// Receives focus on Back when the page supplies no list focus node.
  final FocusNode _compactNavigatorFocus = FocusNode(
    debugLabel: 'workspace-compact-navigator',
    skipTraversal: true,
  );

  /// The compact pane shown by the previous build; null outside compact.
  CompactWorkspacePage? _lastCompactPage;

  /// With the navigator collapsed (the Minimal preset) compact opens on the
  /// canvas; the back bar still reaches the list, and this remembers it did.
  bool _collapsedNavigatorRevealed = false;

  @override
  void dispose() {
    _compactCanvasFocus.dispose();
    _compactNavigatorFocus.dispose();
    super.dispose();
  }

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

  CompactWorkspacePage _compactPageFor(CompactWorkspaceNavigation? nav) {
    if (nav == null) {
      return widget.preferences.navigatorCollapsed
          ? CompactWorkspacePage.canvas
          : widget.compactPage;
    }
    if (nav.wantsCanvas) return CompactWorkspacePage.canvas;
    if (widget.preferences.navigatorCollapsed && !_collapsedNavigatorRevealed) {
      return CompactWorkspacePage.canvas;
    }
    return CompactWorkspacePage.navigator;
  }

  /// Moves focus onto the canvas once it replaces the list — only on that
  /// transition, only for the visible page (IndexedStack disables TickerMode
  /// for hidden ones), and never away from something inside the canvas.
  void _noteCompactPage(CompactWorkspacePage? page) {
    final previous = _lastCompactPage;
    _lastCompactPage = page;
    if (previous != CompactWorkspacePage.navigator ||
        page != CompactWorkspacePage.canvas) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !TickerMode.valuesOf(context).enabled) return;
      if (_compactCanvasFocus.context == null || _compactCanvasFocus.hasFocus) {
        return;
      }
      _compactCanvasFocus.requestFocus();
    });
  }

  void _compactBack() {
    final nav = widget.compactNavigation;
    if (nav == null) return;
    setState(() => _collapsedNavigatorRevealed = true);
    nav.onShowNavigator();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final node =
          widget.compactNavigation?.navigatorFocusNode ??
          _compactNavigatorFocus;
      if (node.context != null && node.canRequestFocus) node.requestFocus();
    });
  }

  /// Esc and ⌘[ go Back — reached only when no descendant handled the key
  /// first, so an open popover, a live drag or a field keeps its own Esc.
  KeyEventResult _onCompactCanvasKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    final back = switch (event.logicalKey) {
      LogicalKeyboardKey.escape =>
        !keyboard.isMetaPressed &&
            !keyboard.isAltPressed &&
            !keyboard.isControlPressed &&
            !keyboard.isShiftPressed,
      LogicalKeyboardKey.bracketLeft =>
        keyboard.isMetaPressed &&
            !keyboard.isAltPressed &&
            !keyboard.isControlPressed &&
            !keyboard.isShiftPressed,
      _ => false,
    };
    if (!back) return KeyEventResult.ignored;
    _compactBack();
    return KeyEventResult.handled;
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
        final nav = widget.compactNavigation;
        _noteCompactPage(
          nav != null &&
                  widget.navigator != null &&
                  !arrangement.navigatorAndCanvas
              ? _compactPageFor(nav)
              : null,
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
      final nav = widget.compactNavigation;
      if (nav == null) {
        if (widget.preferences.navigatorCollapsed) return canvas;
        return widget.compactPage == CompactWorkspacePage.navigator
            ? navigatorRegion
            : canvas;
      }
      if (_compactPageFor(nav) == CompactWorkspacePage.navigator) {
        return WorkspaceFocusRegion(
          role: WorkspacePaneRole.navigator,
          child: nav.navigatorFocusNode == null
              ? Focus(focusNode: _compactNavigatorFocus, child: navigator)
              : navigator,
        );
      }
      return WorkspaceFocusRegion(
        role: WorkspacePaneRole.canvas,
        child: Focus(
          focusNode: _compactCanvasFocus,
          onKeyEvent: _onCompactCanvasKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _CompactBackBar(
                label: nav.navigatorLabel,
                onPressed: _compactBack,
              ),
              Expanded(child: widget.canvas),
            ],
          ),
        ),
      );
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

/// "‹ Commits": the one way back to the list that needs no keyboard.
class _CompactBackBar extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;

  const _CompactBackBar({required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: MacosColors.separatorColor)),
      ),
      alignment: Alignment.centerLeft,
      child: InlineActionButton(
        key: kWorkspaceCompactBackKey,
        label: '‹ $label',
        icon: CupertinoIcons.list_bullet,
        tooltip: 'Back to $label (Esc or ⌘[)',
        onPressed: onPressed,
      ),
    );
  }
}
