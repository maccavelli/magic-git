// The native menu bar is only as good as its wiring: an item whose action id
// no panel handles is a command that looks real, dims wrong, and does nothing.
//
// These checks close that loop end to end — every menu item names a registered
// keymap action, that action is routed to a panel, and that panel's source
// really contains a handler entry for it. The last step reads the panel files
// rather than mounting them because a handler's availability depends on live
// selection state, while its *existence* is what a menu item depends on.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/settings/keymap.dart';
import 'package:remote_magic_git/features/common/menu_bar_spec.dart';
import 'package:remote_magic_git/features/common/panel_actions.dart';

/// The file(s) whose `handlers` map owns each panel's action ids. The forge
/// panel is two files because the GitHub and GitLab panels each own their own
/// host's verbs behind one page index.
const Map<int, List<String>> _panelSources = {
  kRepositoryPanel: ['lib/features/repository/repo_status_view.dart'],
  kHistoryPanel: ['lib/features/history/history_view.dart'],
  kBranchesPanel: ['lib/features/branches/branch_navigator.dart'],
  kStashesPanel: ['lib/features/stash/stash_view.dart'],
  kForgePanel: [
    'lib/features/github/github_panel.dart',
    'lib/features/gitlab/gitlab_panel.dart',
  ],
  kWorktreesPanel: ['lib/features/worktrees/worktrees_view.dart'],
};

String _read(String path) => File(path).readAsStringSync();

void main() {
  test('every menu item names a registered keymap action', () {
    for (final id in menuBarActionIds()) {
      expect(
        kKeymapActionsById,
        contains(id),
        reason: 'menu item action $id is not in kKeymapActions',
      );
    }
  });

  // 0009 H1: the session-reachable set must stay a subset of the registered
  // world (keymap + panel routing), and selection-gated verbs must never
  // sneak in — those only enable through the owning panel's live handlers.
  test('cross-panel ids are registered, routed, and never selection-gated', () {
    for (final id in kCrossPanelMenuActionIds) {
      expect(
        kKeymapActionsById,
        contains(id),
        reason: 'cross-panel id $id is not in kKeymapActions',
      );
      expect(
        kPanelActionOwner,
        contains(id),
        reason: 'cross-panel id $id has no owning panel',
      );
    }
    for (final gated in const [
      'stashes.apply',
      'stashes.pop',
      'stashes.drop',
      'branches.delete',
      'branches.merge',
      'branches.publish',
      'worktrees.remove',
      'worktrees.repair',
      'github.merge',
      'gitlab.merge',
      'history.checkout',
      'repository.abortPending',
    ]) {
      expect(
        kCrossPanelMenuActionIds,
        isNot(contains(gated)),
        reason: '$gated needs a live selection — it must stay panel-gated',
      );
    }
  });

  test('every menu item is routed to an owning panel', () {
    expect(
      unroutableMenuActionIds(),
      isEmpty,
      reason: 'these menu ids have no entry in kPanelActionOwner',
    );
  });

  test('every menu item resolves to a handler in its owning panel', () {
    for (final id in menuBarActionIds()) {
      final panel = panelOwnerOf(id);
      // Shell-scoped ids (File ▸ New/Close Tab) run through AppShell's
      // _globalHandlers map instead of a panel (0009 M4).
      final sources = panel == null
          ? const ['lib/features/app_shell.dart']
          : _panelSources[panel]!;
      final wired = sources.any((path) => _read(path).contains("'$id':"));
      expect(
        wired,
        isTrue,
        reason:
            'no handler entry for $id in ${sources.join(" or ")} — the menu '
            'item would be permanently dimmed',
      );
    }
  });

  test('the routing table has no ids the keymap does not know', () {
    for (final id in kPanelActionOwner.keys) {
      expect(
        kKeymapActionsById,
        contains(id),
        reason: 'routing entry $id is not a registered keymap action',
      );
    }
  });

  test('the structure survives the channel encoding', () {
    final payload = menuBarChannelPayload();
    expect(payload.length, kMenuBarMenus.length);

    // Swift walks exactly these keys; a rename here silently empties a menu.
    // File leads (Swift repositions it after the app menu); Repository is
    // the first repository-facing menu.
    expect(payload.first['title'], 'File');
    final repository = payload[1];
    expect(repository['title'], 'Repository');
    final items = repository['items']! as List<Object?>;
    expect(items, isNotEmpty);

    final pull = items.cast<Map<String, Object?>>().firstWhere(
      (item) => item['title'] == 'Pull',
    );
    expect(pull['items'], isA<List<Object?>>());
    expect(
      (pull['items']! as List<Object?>).length,
      3,
      reason: 'Pull carries its variants so none is state-hidden',
    );
    expect(
      pull.containsKey('actionId'),
      isFalse,
      reason: 'a submenu parent must not also be a command',
    );

    expect(
      items.cast<Map<String, Object?>>().any(
        (item) => item['separator'] == true,
      ),
      isTrue,
    );
  });

  test('destructive commands are marked as such', () {
    final destructive = <String>{};
    for (final menu in kMenuBarMenus) {
      void walk(Iterable<MenuBarItem> items) {
        for (final item in items) {
          if (item.destructive && item.actionId != null) {
            destructive.add(item.actionId!);
          }
          walk(item.items);
        }
      }

      walk(menu.items);
    }

    expect(destructive, {
      'repository.forcePush',
      'repository.forcePushHard',
      'repository.abortPending',
      'branches.delete',
      'stashes.drop',
      'stashes.clearAll',
      'worktrees.remove',
    });
  });

  test('no command appears in two menus', () {
    final seen = <String>{};
    for (final menu in kMenuBarMenus) {
      for (final id in menu.actionIds) {
        expect(
          seen.add(id),
          isTrue,
          reason: '$id appears in more than one menu',
        );
      }
    }
  });
}
