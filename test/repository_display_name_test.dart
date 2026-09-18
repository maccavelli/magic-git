// MADR 0052: the one repository name shared by the tab title, window title,
// sidebar Repository row and status bar — the tab's alias when set, else the
// last directory of the repo path, and the alias only for the session's repo.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/features/tabs/tab_ui_providers.dart';

class _StubConnection extends ConnectionController {
  @override
  ConnectionState build() => const ConnectionState(
    phase: ConnectionPhase.connected,
    repoPath: _repo,
    repoPaths: [_repo],
  );
}

const _repo = '/srv/backend-src';

ProviderContainer _container() {
  final container = ProviderContainer(
    retry: (_, _) => null,
    overrides: [connectionProvider.overrideWith(_StubConnection.new)],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('repositoryDisplayName', () {
    test('T1.1 no alias gives the last directory', () {
      expect(repositoryDisplayName('/srv/backend-src'), 'backend-src');
    });

    test('T1.2 a trailing slash still gives the last directory', () {
      expect(repositoryDisplayName('/srv/backend-src/'), 'backend-src');
    });

    test('T1.3 an alias wins', () {
      expect(repositoryDisplayName(_repo, alias: 'Backend'), 'Backend');
    });

    test('T1.4 a blank alias falls back to the directory', () {
      expect(repositoryDisplayName(_repo, alias: '   '), 'backend-src');
    });

    test('T1.5 an alias is trimmed', () {
      expect(repositoryDisplayName(_repo, alias: '  Backend  '), 'Backend');
    });

    test('T1.6 a null alias gives the directory', () {
      expect(repositoryDisplayName(_repo, alias: null), 'backend-src');
    });
  });

  group('repositoryDisplayNameProvider', () {
    test('T1.7 no alias gives the directory', () {
      final container = _container();
      expect(
        container.read(repositoryDisplayNameProvider(_repo)),
        'backend-src',
      );
    });

    test('T1.8 the tab alias names the session repo', () {
      final container = _container();
      container.read(tabAliasProvider.notifier).set('Backend');
      expect(container.read(repositoryDisplayNameProvider(_repo)), 'Backend');
    });

    test('T1.9 the alias does not apply to another path', () {
      final container = _container();
      container.read(tabAliasProvider.notifier).set('Backend');
      expect(
        container.read(repositoryDisplayNameProvider('/srv/other')),
        'other',
      );
    });

    test('T1.10 follows the alias as it is set and cleared', () async {
      final container = _container();
      final seen = <String>[];
      container.listen(
        repositoryDisplayNameProvider(_repo),
        (_, next) => seen.add(next),
        fireImmediately: true,
      );
      // Riverpod 3 delivers a dependant's update on the next flush, not
      // synchronously, so each change is pumped before the next.
      container.read(tabAliasProvider.notifier).set('Backend');
      await container.pump();
      container.read(tabAliasProvider.notifier).set('');
      await container.pump();
      expect(seen, ['backend-src', 'Backend', 'backend-src']);
    });
  });
}
