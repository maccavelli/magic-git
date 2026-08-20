// recentWorkspacesProvider: merges saved SSH connections and saved local repos
// into one list, newest-first by lastConnectedAt, capped at 3, with never-used
// entries sorted last.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/storage/saved_connection.dart';
import 'package:remote_magic_git/core/storage/saved_local_repo.dart';

SavedConnection _c(String id, DateTime? at) => SavedConnection(
  id: id,
  label: id,
  host: 'h',
  port: 22,
  username: 'u',
  repoPath: '/r',
  lastConnectedAt: at,
);

SavedLocalRepo _l(String id, DateTime? at) => SavedLocalRepo(
  id: id,
  label: id,
  repoPath: '/local/$id',
  lastConnectedAt: at,
);

ProviderContainer _container({
  List<SavedConnection> conns = const [],
  List<SavedLocalRepo> locals = const [],
}) {
  final c = ProviderContainer(
    overrides: [
      savedConnectionsProvider.overrideWith((ref) => conns),
      savedLocalReposProvider.overrideWith((ref) => locals),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

Future<void> _warm(ProviderContainer c) async {
  await c.read(savedConnectionsProvider.future);
  await c.read(savedLocalReposProvider.future);
}

void main() {
  test('merges connections and local repos, newest first, capped at 3', () async {
    final c = _container(
      conns: [
        _c('conn-old', DateTime.utc(2026, 1, 1)),
        _c('conn-new', DateTime.utc(2026, 6, 1)),
      ],
      locals: [
        _l('local-mid', DateTime.utc(2026, 3, 1)),
        _l('local-newest', DateTime.utc(2026, 8, 1)),
      ],
    );
    await _warm(c);

    final recent = c.read(recentWorkspacesProvider);
    // Newest first across BOTH stores; the 4th (conn-old) is dropped by the cap.
    expect(recent.map((w) => w.displayName).toList(), [
      'local-newest',
      'conn-new',
      'local-mid',
    ]);
    // Each entry keeps its concrete type so the landing card can dispatch it.
    expect(recent[0], isA<RecentLocalRepo>());
    expect(recent[1], isA<RecentConnection>());
  });

  test(
    'never-used entries sort last; connections precede locals on a tie',
    () async {
      // Both null timestamps -> comparator treats them equal, so ordering falls
      // back to stored order, and connections are appended before local repos.
      final c = _container(
        conns: [_c('conn', null)],
        locals: [_l('local', null)],
      );
      await _warm(c);
      expect(
        c.read(recentWorkspacesProvider).map((w) => w.displayName).toList(),
        ['conn', 'local'],
      );
    },
  );

  test('a used local repo outranks a never-used connection', () async {
    final c = _container(
      conns: [_c('conn-never', null)],
      locals: [_l('local-used', DateTime.utc(2026, 2, 1))],
    );
    await _warm(c);
    expect(
      c.read(recentWorkspacesProvider).map((w) => w.displayName).toList(),
      ['local-used', 'conn-never'],
    );
  });

  test('is empty when nothing is saved', () async {
    final c = _container();
    await _warm(c);
    expect(c.read(recentWorkspacesProvider), isEmpty);
  });

  test(
    'shows a local repo even with no saved connections (the reported bug)',
    () async {
      final c = _container(
        locals: [_l('only-local', DateTime.utc(2026, 5, 1))],
      );
      await _warm(c);
      final recent = c.read(recentWorkspacesProvider);
      expect(recent, hasLength(1));
      expect(recent.single, isA<RecentLocalRepo>());
      expect(recent.single.displayName, 'only-local');
    },
  );
}
