import 'package:flutter/cupertino.dart' hide ConnectionState;
import 'package:flutter/material.dart'
    show ReorderableDragStartListener, ReorderableListView;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/providers/app_providers.dart';
import '../common/session_exit_guard.dart';
import '../common/tappable.dart';
import 'tabs_controller.dart';
import 'tabs_scope.dart';

String _basename(String path) {
  final parts = path.split('/').where((s) => s.isNotEmpty).toList();
  return parts.isEmpty ? path : parts.last;
}

/// Browser-style tab row across the top of the main window: one chip per open
/// repository, the active one highlighted, each closable, plus a "+" to open a
/// fresh landing tab. Hidden entirely while a single tab is open, so a
/// one-repo session looks exactly as it did before tabs existed.
class TabStrip extends ConsumerWidget {
  const TabStrip({super.key});

  Future<void> _closeTab(
    BuildContext context,
    TabsController controller,
    RepoTab tab,
  ) async {
    // Confirm against THIS tab's session — the close target may be background.
    final conn = tab.container.read(connectionProvider);
    final repoPath = conn.repoPath;
    if (repoPath != null && conn.isConnected) {
      final ok = await confirmSessionExit(
        context,
        tab.container,
        repoPath: repoPath,
        title: 'Close tab?',
      );
      if (!ok || !context.mounted) return;
    }
    await controller.close(tab.id);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = TabsScope.of(context);
    final tabs = controller.tabs;
    // A single tab is the pre-tabs experience — no strip.
    if (tabs.length <= 1) return const SizedBox.shrink();

    // Resolve the bar's colors from the (dark) app theme rather than fixed
    // MacosColors, whose base variants are the LIGHT ones — the source of the
    // white bar / invisible white text.
    final theme = MacosTheme.of(context);
    return Container(
      height: 36,
      decoration: BoxDecoration(
        color: theme.canvasColor,
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      child: Row(
        children: [
          Expanded(
            child: ReorderableListView.builder(
              scrollDirection: Axis.horizontal,
              buildDefaultDragHandles: false,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              itemCount: tabs.length,
              onReorderItem: controller.reorder,
              // A flat proxy while dragging — the default Material elevation
              // shadow looks wrong against the macOS chrome.
              proxyDecorator: (child, index, animation) => child,
              itemBuilder: (context, i) {
                final tab = tabs[i];
                return ReorderableDragStartListener(
                  key: ValueKey(tab.id),
                  index: i,
                  child: _TabChip(
                    tab: tab,
                    active: tab.id == controller.activeId,
                    onTap: () => controller.activate(tab.id),
                    onClose: () => _closeTab(context, controller, tab),
                  ),
                );
              },
            ),
          ),
          MacosTooltip(
            message: controller.canOpenTab
                ? 'New tab'
                : 'Maximum of ${TabsController.maxTabs} tabs open',
            child: MacosIconButton(
              icon: const MacosIcon(CupertinoIcons.add, size: 15),
              boxConstraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              // Canonical cursor policy (common/buttons.dart): hand when
              // clickable, arrow at the cap.
              mouseCursor: controller.canOpenTab
                  ? SystemMouseCursors.click
                  : SystemMouseCursors.basic,
              // Disabled at the cap (a null handler greys it out).
              onPressed: controller.canOpenTab ? controller.newTab : null,
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }
}

class _TabChip extends StatelessWidget {
  const _TabChip({
    required this.tab,
    required this.active,
    required this.onTap,
    required this.onClose,
  });

  final RepoTab tab;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    // The tab's live session (non-autoDispose, always present). Reactive rebuild
    // is driven by TabsController.notifyListeners on connection change, watched
    // via TabsScope.of above — so this synchronous read is always current.
    final conn = tab.container.read(connectionProvider);
    final isLocal = conn.isLocal;
    final label = tab.isBlank
        ? 'New Tab'
        : (tab.repoPath != null ? _basename(tab.repoPath!) : 'Connecting…');

    return Semantics(
      button: true,
      selected: active,
      label: label,
      child: Tappable(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          width: 168,
          margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
          padding: const EdgeInsets.only(left: 10, right: 4),
          decoration: BoxDecoration(
            color: active
                ? MacosColors.systemBlueColor.withValues(alpha: 0.16)
                : null,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              MacosIcon(
                tab.isBlank
                    ? CupertinoIcons.plus_app
                    : isLocal
                    ? CupertinoIcons.folder
                    : CupertinoIcons.desktopcomputer,
                size: 13,
                color: active
                    ? MacosColors.systemBlueColor
                    : MacosColors.systemGrayColor,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: typography.caption1.copyWith(
                    fontWeight: active ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
              ),
              _CloseButton(onClose: onClose),
            ],
          ),
        ),
      ),
    );
  }
}

/// The per-chip close affordance: a small ✕ that ends that tab's session.
class _CloseButton extends StatelessWidget {
  const _CloseButton({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return MacosIconButton(
      icon: const MacosIcon(CupertinoIcons.xmark, size: 11),
      boxConstraints: const BoxConstraints(minWidth: 22, minHeight: 22),
      padding: EdgeInsets.zero,
      mouseCursor: SystemMouseCursors.click,
      onPressed: onClose,
    );
  }
}
