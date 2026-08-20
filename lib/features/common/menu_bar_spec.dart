/// The native menu bar's contents, declared in Dart.
///
/// macOS expects every toolbar command to also be a menu command: "Make every
/// toolbar item available as a command in the menu bar" (Apple HIG, Toolbars),
/// and "If all of a menu's items are unavailable, the menu itself needs to
/// remain available so people can open it and learn about the commands it
/// contains" — which is why unavailable items dim here rather than disappear.
///
/// The structure lives on this side rather than in `MainFlutterWindow.swift`
/// so there is exactly one place where a command's existence, its title and
/// its owning action id are stated. Swift is a generic builder: it receives
/// [menuBarChannelPayload], installs the menus, and reports a click back as the
/// action id it was given. Nothing about a specific command is hard-coded
/// natively, so adding a command is a one-line change here plus the panel
/// handler that actually performs it.
library;

import 'panel_actions.dart';

/// One row in a native menu. Either a command ([actionId] set), a separator
/// ([separator]), or a submenu parent ([items] non-empty).
class MenuBarItem {
  final String title;

  /// The keymap action id dispatched when the item is chosen. Null for
  /// separators and submenu parents.
  final String? actionId;

  /// Single-character key equivalent, e.g. `'r'`. Empty means no shortcut.
  /// Only set this where the app has no conflicting binding — a menu key
  /// equivalent wins over Flutter's own handling.
  final String key;

  /// Modifiers for [key]: any of `command`, `shift`, `option`, `control`.
  final List<String> modifiers;

  /// Renders in the destructive style and, for the ones that cannot be undone,
  /// is what marks them as needing confirmation before they run.
  final bool destructive;

  final bool separator;
  final List<MenuBarItem> items;

  const MenuBarItem(
    this.title,
    this.actionId, {
    this.key = '',
    this.modifiers = const ['command'],
    this.destructive = false,
  }) : separator = false,
       items = const [];

  const MenuBarItem.separator()
    : title = '',
      actionId = null,
      key = '',
      modifiers = const [],
      destructive = false,
      separator = true,
      items = const [];

  const MenuBarItem.submenu(this.title, this.items)
    : actionId = null,
      key = '',
      modifiers = const [],
      destructive = false,
      separator = false;

  Map<String, Object?> toChannel() => {
    'title': title,
    if (actionId != null) 'actionId': actionId,
    'key': key,
    'modifiers': modifiers,
    'destructive': destructive,
    'separator': separator,
    if (items.isNotEmpty) 'items': [for (final item in items) item.toChannel()],
  };

  /// Every command id in this item's subtree.
  Iterable<String> get actionIds sync* {
    final id = actionId;
    if (id != null) yield id;
    for (final item in items) {
      yield* item.actionIds;
    }
  }
}

class MenuBarMenu {
  final String title;
  final List<MenuBarItem> items;

  const MenuBarMenu(this.title, this.items);

  Map<String, Object?> toChannel() => {
    'title': title,
    'items': [for (final item in items) item.toChannel()],
  };

  Iterable<String> get actionIds sync* {
    for (final item in items) {
      yield* item.actionIds;
    }
  }
}

/// The repository-facing menus, inserted before the Window menu in the order
/// given — except the File menu, which Swift places right after the app menu
/// (its conventional macOS position). The app, Edit, View, Window and Help
/// menus stay as they are — View keeps its own natively-installed toggles.
const List<MenuBarMenu> kMenuBarMenus = [
  // Tab lifecycle (0009 M4). New Tab shows its ⌘T equivalent; Close Tab
  // ships unbound (⌘W is viewer-owned — see keymap.dart) so this menu item
  // is its discoverable route.
  MenuBarMenu('File', [
    MenuBarItem('New Tab', 'global.newTab', key: 't'),
    MenuBarItem('Close Tab', 'global.closeTab'),
  ]),
  MenuBarMenu('Repository', [
    MenuBarItem('Fetch', 'repository.fetch'),
    MenuBarItem.submenu('Pull', [
      MenuBarItem('Pull', 'repository.pull'),
      MenuBarItem('Pull with Rebase', 'repository.pullRebase'),
      MenuBarItem('Pull with Merge', 'repository.pullMerge'),
    ]),
    MenuBarItem.submenu('Push', [
      MenuBarItem('Push', 'repository.push'),
      MenuBarItem('Push and Set Upstream', 'repository.pushSetUpstream'),
      MenuBarItem('Push Tags', 'repository.pushTags'),
      // The existing `repository.forcePush` id has always meant --force-with-
      // lease (its keymap label says so); the unconditional force is the
      // separate, more dangerous verb.
      MenuBarItem(
        'Force Push with Lease',
        'repository.forcePush',
        destructive: true,
      ),
      MenuBarItem('Force Push', 'repository.forcePushHard', destructive: true),
    ]),
    MenuBarItem('Sync', 'repository.sync'),
    MenuBarItem.separator(),
    MenuBarItem('Stage All', 'repository.stageAll'),
    MenuBarItem('Unstage All', 'repository.unstageAll'),
    MenuBarItem('Commit…', 'repository.focusCommit'),
    MenuBarItem('Amend Last Commit…', 'repository.amend'),
    MenuBarItem.separator(),
    MenuBarItem('Stash Changes', 'repository.stash'),
    MenuBarItem.separator(),
    MenuBarItem(
      'Abort Pending Operation…',
      'repository.abortPending',
      destructive: true,
    ),
  ]),
  MenuBarMenu('Branch', [
    MenuBarItem('New Branch…', 'branches.newBranch'),
    MenuBarItem('New Tag…', 'branches.createTag'),
    MenuBarItem.separator(),
    MenuBarItem('Publish Branch', 'branches.publish'),
    MenuBarItem('Create Pull or Merge Request', 'branches.createRequest'),
    MenuBarItem('Compare with Base', 'branches.compare'),
    MenuBarItem('Open CI', 'branches.openCi'),
    MenuBarItem.separator(),
    MenuBarItem('Merge into Current Branch', 'branches.merge'),
    MenuBarItem('Delete Branch…', 'branches.delete', destructive: true),
  ]),
  MenuBarMenu('Stash', [
    MenuBarItem('Stash with Message…', 'stashes.stashWithMessage'),
    MenuBarItem.separator(),
    MenuBarItem('Apply Stash', 'stashes.apply'),
    MenuBarItem('Pop Stash', 'stashes.pop'),
    MenuBarItem('Drop Stash…', 'stashes.drop', destructive: true),
    MenuBarItem.separator(),
    MenuBarItem('Apply Latest Stash', 'stashes.applyLatest'),
    MenuBarItem('Pop Latest Stash', 'stashes.popLatest'),
    MenuBarItem.separator(),
    MenuBarItem('Clear All Stashes…', 'stashes.clearAll', destructive: true),
  ]),
  MenuBarMenu('Forge', [
    MenuBarItem('New Issue…', 'forge.newIssue'),
    MenuBarItem('New Pull Request…', 'github.newPr'),
    MenuBarItem('New Merge Request…', 'gitlab.newMr'),
    MenuBarItem.separator(),
    MenuBarItem('Approve', 'github.approve'),
    MenuBarItem('Approve Merge Request', 'gitlab.approve'),
    MenuBarItem('Merge Pull Request…', 'github.merge'),
    MenuBarItem('Merge Merge Request…', 'gitlab.merge'),
    MenuBarItem.separator(),
    // Enabling auto-merge is deliberately absent: it needs the computed merge
    // readiness plan for a specific request, which exists only in the detail
    // pane that offers it. A menu item for it could never be enabled, and an
    // item that is always dimmed teaches nothing. Cancelling needs only the
    // request id, so it is here.
    MenuBarItem('Cancel Auto-merge', 'forge.cancelAutoMerge'),
    MenuBarItem.separator(),
    MenuBarItem('Re-run Failed Jobs', 'github.rerun'),
    MenuBarItem('Retry Pipeline', 'gitlab.retry'),
  ]),
  MenuBarMenu('Worktree', [
    MenuBarItem('Add Worktree…', 'worktrees.add'),
    MenuBarItem('Open Worktree', 'worktrees.open'),
    MenuBarItem.separator(),
    MenuBarItem('Lock Worktree', 'worktrees.lock'),
    MenuBarItem('Unlock Worktree', 'worktrees.unlock'),
    MenuBarItem('Move Worktree…', 'worktrees.move'),
    MenuBarItem.separator(),
    MenuBarItem('Repair Worktree', 'worktrees.repair'),
    MenuBarItem('Repair All Worktree Links', 'worktrees.repairAll'),
    MenuBarItem('Prune Stale Worktrees', 'worktrees.prune'),
    MenuBarItem.separator(),
    MenuBarItem('Remove Worktree…', 'worktrees.remove', destructive: true),
  ]),
];

/// The payload handed to Swift's `installMenus`.
List<Map<String, Object?>> menuBarChannelPayload() => [
  for (final menu in kMenuBarMenus) menu.toChannel(),
];

/// Every action id the menu bar can dispatch.
Set<String> menuBarActionIds() => {
  for (final menu in kMenuBarMenus) ...menu.actionIds,
};

/// Menu ids with no route at all — always empty in a correct build, and
/// asserted to be so by `menu_bar_spec_test.dart`. `global.*` ids are routed
/// by the shell itself (the menu-request listener falls through to
/// `_globalHandlers`), so only non-global ids need a panel owner.
Set<String> unroutableMenuActionIds() => menuBarActionIds()
    .where((id) => panelOwnerOf(id) == null && !id.startsWith('global.'))
    .toSet();
