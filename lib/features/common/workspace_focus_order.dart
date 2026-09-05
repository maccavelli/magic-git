import 'package:flutter/widgets.dart';
import 'package:macos_ui/macos_ui.dart';

import 'repository_workspace_models.dart';
import 'workspace_appearance.dart';

/// Stable keyboard/VoiceOver order for every repository-centered screen.
double workspacePaneFocusOrder(WorkspacePaneRole role) => switch (role) {
  WorkspacePaneRole.repositoryContext => 1,
  WorkspacePaneRole.navigator => 2,
  WorkspacePaneRole.canvas => 4,
  WorkspacePaneRole.inspector => 5,
  WorkspacePaneRole.taskDock => 6,
  WorkspacePaneRole.activity => 7,
};

String workspacePaneSemanticsLabel(WorkspacePaneRole role) => switch (role) {
  WorkspacePaneRole.repositoryContext => 'Repository context',
  WorkspacePaneRole.navigator => 'Repository navigator',
  WorkspacePaneRole.canvas => 'Repository canvas',
  WorkspacePaneRole.inspector => 'Repository inspector',
  WorkspacePaneRole.taskDock => 'Repository task dock',
  WorkspacePaneRole.activity => 'Repository activity',
};

/// Routes the unbound-by-default pane-focus actions to the visible workspace.
/// IndexedStack disables TickerMode for hidden screens, which lets the
/// registry reject their still-mounted focus nodes without coupling the
/// feature-neutral scaffold to AppShell's page index.
class WorkspacePaneFocusRegistry {
  WorkspacePaneFocusRegistry._();

  static final instance = WorkspacePaneFocusRegistry._();
  final Map<WorkspacePaneRole, Set<FocusNode>> _nodes = {};

  /// Set for the duration of a [request] so the region that gains focus can
  /// tell WHY it did.
  ///
  /// The ring exists to show where the pane-focus shortcuts moved focus to —
  /// that is its only job. But `Focus.onFocusChange` fires when the node **or
  /// any descendant** takes focus, so clicking a file in the canvas list
  /// (`repo_status_view.dart` requests its list node) looked identical to the
  /// shortcut and ringed the entire pane. A focus ring on a mouse click is
  /// against the platform convention and was, in practice, just noise.
  bool _viaShortcut = false;

  /// True exactly once per [request], for the region that gains focus from it.
  bool consumeShortcutFocus() {
    final was = _viaShortcut;
    _viaShortcut = false;
    return was;
  }

  void register(WorkspacePaneRole role, FocusNode node) {
    (_nodes[role] ??= <FocusNode>{}).add(node);
  }

  void unregister(WorkspacePaneRole role, FocusNode node) {
    _nodes[role]?.remove(node);
  }

  bool request(WorkspacePaneRole role) {
    final candidates = _nodes[role];
    if (candidates == null) return false;
    for (final node in candidates.toList().reversed) {
      final context = node.context;
      if (!node.canRequestFocus ||
          context == null ||
          !TickerMode.valuesOf(context).enabled) {
        continue;
      }
      _viaShortcut = true;
      node.requestFocus();
      // Not cleared here: `onFocusChange` runs after this returns, and the
      // region consumes the flag then. It is cleared on the no-candidate path
      // below so a refused request cannot leak a ring onto the next, unrelated
      // focus change.
      return true;
    }
    _viaShortcut = false;
    return false;
  }
}

/// Marks a workspace role for deterministic traversal, semantics, direct
/// focus, and a visible focus ring that is distinct from row selection.
class WorkspaceFocusRegion extends StatefulWidget {
  final WorkspacePaneRole role;
  final Widget child;

  const WorkspaceFocusRegion({
    super.key,
    required this.role,
    required this.child,
  });

  @override
  State<WorkspaceFocusRegion> createState() => _WorkspaceFocusRegionState();
}

class _WorkspaceFocusRegionState extends State<WorkspaceFocusRegion> {
  late final FocusNode _node = FocusNode(
    debugLabel: workspacePaneSemanticsLabel(widget.role),
    skipTraversal: true,
  );
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    WorkspacePaneFocusRegistry.instance.register(widget.role, _node);
  }

  @override
  void didUpdateWidget(WorkspaceFocusRegion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.role == widget.role) return;
    WorkspacePaneFocusRegistry.instance.unregister(oldWidget.role, _node);
    WorkspacePaneFocusRegistry.instance.register(widget.role, _node);
  }

  @override
  void dispose() {
    WorkspacePaneFocusRegistry.instance.unregister(widget.role, _node);
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final focusColor =
        WorkspaceAppearanceScope.maybeOf(context)?.tokens.palette.focus ??
        MacosTheme.of(context).primaryColor;
    return FocusTraversalOrder(
      order: NumericFocusOrder(workspacePaneFocusOrder(widget.role)),
      child: Semantics(
        container: true,
        label: workspacePaneSemanticsLabel(widget.role),
        child: Focus(
          focusNode: _node,
          onFocusChange: (focused) {
            // Ring only when the pane-focus SHORTCUT put focus here. Focus
            // arriving because the user clicked something inside the pane is
            // not what this indicator is for.
            final show =
                focused &&
                WorkspacePaneFocusRegistry.instance.consumeShortcutFocus();
            if (_focused != show) setState(() => _focused = show);
          },
          // A pointer press anywhere dismisses the ring, including inside the
          // pane that already has it — where focus does not change and
          // `onFocusChange` would never fire. Translucent so it observes
          // without consuming.
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (_) {
              if (_focused) setState(() => _focused = false);
            },
            child: AnimatedContainer(
              duration: reduceMotion
                  ? Duration.zero
                  : const Duration(milliseconds: 90),
              foregroundDecoration: BoxDecoration(
                border: _focused
                    ? Border.all(color: focusColor, width: 2)
                    : null,
              ),
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}
