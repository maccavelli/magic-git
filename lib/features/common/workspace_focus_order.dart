import 'package:flutter/widgets.dart';
import 'package:macos_ui/macos_ui.dart';

import 'repository_workspace_models.dart';

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
      node.requestFocus();
      return true;
    }
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
    return FocusTraversalOrder(
      order: NumericFocusOrder(workspacePaneFocusOrder(widget.role)),
      child: Semantics(
        container: true,
        label: workspacePaneSemanticsLabel(widget.role),
        child: Focus(
          focusNode: _node,
          onFocusChange: (focused) {
            if (_focused != focused) setState(() => _focused = focused);
          },
          child: AnimatedContainer(
            duration: reduceMotion
                ? Duration.zero
                : const Duration(milliseconds: 90),
            foregroundDecoration: BoxDecoration(
              border: _focused
                  ? Border.all(
                      color: MacosTheme.of(context).primaryColor,
                      width: 2,
                    )
                  : null,
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
