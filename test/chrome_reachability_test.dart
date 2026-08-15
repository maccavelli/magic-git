// The no-regression gate for deleting the Repository screen's second toolbar
// band: every command it was the only home for still has at least one route,
// and the ambient state it displayed still has a place to be displayed.
//
// The band carried nine things (MADR 0008 §Phase 4). Six were commands, three
// were passive state. This file checks all nine.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/settings/keymap.dart';
import 'package:remote_magic_git/features/common/menu_bar_spec.dart';
import 'package:remote_magic_git/features/common/repository_context.dart';

const _repoStatusView = 'lib/features/repository/repo_status_view.dart';
const _contextBar = 'lib/features/common/repository_context_bar.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  test('the band itself is gone', () {
    final source = _read(_repoStatusView);
    expect(
      source.contains('Widget _header('),
      isFalse,
      reason: 'the second toolbar band is still being built',
    );
    expect(
      source.contains('Widget _toolButton('),
      isFalse,
      reason: 'its icon-button helper outlived it',
    );
  });

  group('every command it owned kept a route', () {
    // Each of these was reachable ONLY from the band before this change.
    const orphans = {
      'Pull with rebase': 'repository.pullRebase',
      'Pull with merge': 'repository.pullMerge',
      'Push and set upstream': 'repository.pushSetUpstream',
      'Push tags': 'repository.pushTags',
      'Force push (with lease)': 'repository.forcePush',
      'Force push': 'repository.forcePushHard',
      'Amend last commit (working tree)': 'repository.amend',
    };

    test('as a registered, addressable keymap action', () {
      for (final MapEntry(key: verb, value: id) in orphans.entries) {
        expect(
          kKeymapActionsById,
          contains(id),
          reason: '$verb lost its only route when the band was deleted',
        );
      }
    });

    test('as a handler in the Repository panel', () {
      final source = _read(_repoStatusView);
      for (final MapEntry(key: verb, value: id) in orphans.entries) {
        expect(
          source.contains("'$id':"),
          isTrue,
          reason: '$verb has an id but nothing runs it',
        );
      }
    });

    test('and as a menu-bar item', () {
      final menuIds = menuBarActionIds();
      for (final MapEntry(key: verb, value: id) in orphans.entries) {
        expect(menuIds, contains(id), reason: '$verb is not in any menu');
      }
    });

    test('the sync verbs additionally kept a button, via the sync group', () {
      // Fetch, Pull, Push and Sync were icon buttons in the band; they are
      // labelled buttons in the context bar now, and their variants are one
      // click away in the group's overflow.
      final source = _read(_repoStatusView);
      for (final command in RepositorySyncCommand.values) {
        expect(
          source.contains('RepositorySyncCommand.${command.name}:'),
          isTrue,
          reason:
              '${command.name} has no implementation in the Repository '
              'panel, so its button would do nothing',
        );
      }
    });

    test('Stash and Refresh kept a button too, on the context bar', () {
      final bar = _read(_contextBar);
      expect(bar.contains('final VoidCallback? onStash;'), isTrue);
      expect(bar.contains('final VoidCallback? onRefresh;'), isTrue);

      final view = _read(_repoStatusView);
      expect(view.contains('onStash:'), isTrue);
      expect(view.contains('onRefresh:'), isTrue);
    });

    test('Settings moved to the app menu, which had to be wired first', () {
      // MainMenu.xib has always carried a ⌘, "Preferences…" item. Ventura+
      // retitles it Settings and enables it only for showSettingsWindow: —
      // a Preferences-prefix match plus enabledActionIds left it dimmed.
      final swift = _read('macos/Runner/MainFlutterWindow.swift');
      expect(swift.contains('installPreferencesAction'), isTrue);
      expect(swift.contains('isSettingsMenuItem'), isTrue);
      expect(swift.contains('hasPrefix("Settings")'), isTrue);
      expect(swift.contains('showSettingsWindow'), isTrue);
      expect(swift.contains('"global.openSettings"'), isTrue);

      final delegate = _read('macos/Runner/AppDelegate.swift');
      expect(delegate.contains('showSettingsWindow'), isTrue);
      expect(delegate.contains('showPreferencesWindow'), isTrue);

      final xib = _read('macos/Runner/Base.lproj/MainMenu.xib');
      expect(xib.contains('showSettingsWindow:'), isTrue);
    });

    test('Refresh also reached the View menu', () {
      final swift = _read('macos/Runner/MainFlutterWindow.swift');
      expect(swift.contains('"global.refresh"'), isTrue);
    });
  });

  group('the passive state it displayed found a home', () {
    test('the watcher dot, as repository-identity state', () {
      expect(
        RepositoryWatchHealth.values,
        containsAll([
          RepositoryWatchHealth.live,
          RepositoryWatchHealth.degraded,
          RepositoryWatchHealth.stopped,
        ]),
      );
      expect(_read(_contextBar).contains('snapshot.watchHealth'), isTrue);
      expect(_read(_repoStatusView).contains('watchHealth:'), isTrue);
    });

    test('the empty/no-remote captions, as an identity notice', () {
      final view = _read(_repoStatusView);
      expect(view.contains("'No remote detected'"), isTrue);
      expect(view.contains("'No branches yet — repository is empty'"), isTrue);
      expect(_read(_contextBar).contains('snapshot.notice'), isTrue);
    });

    test('the SSH link/latency strip, which had no other home in the app', () {
      final bar = _read(_contextBar);
      expect(bar.contains('SshLinkStatusRow()'), isTrue);
      expect(_read(_repoStatusView).contains('showLinkStatus:'), isTrue);
    });

    test('the branch name and divergence were deleted, not relocated — the '
        'context bar already showed both', () {
      final view = _read(_repoStatusView);
      expect(
        view.contains("'↑\${branch.ahead}'"),
        isFalse,
        reason: 'the duplicate badge is back',
      );
    });
  });
}
