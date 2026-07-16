// recentReposProvider: the repo-centric landing list. Flattens each saved SSH
// connection into one entry per known repo path (default first) and adds every
// saved local repo, newest-first by lastConnectedAt, so a user clicks a
// specific repo instead of a connection.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/storage/saved_connection.dart';
import 'package:remote_magic_git/core/storage/saved_local_repo.dart';

SavedConnection _c(
  String id,
  DateTime? at, {
  String repoPath = '/srv/main',
  List<String> repoPaths = const [],
}) => SavedConnection(
  id: id,
  label: id,
  host: 'h',
  port: 22,
  username: 'u',
  repoPath: repoPath,
  repoPaths: repoPaths,
  lastConnectedAt: at,
);

SavedLocalRepo _l(String id, DateTime? at, {String repoPath = ''}) =>
    SavedLocalRepo(
      id: id,
      label: id,
      repoPath: repoPath.isEmpty ? '/Users/me/code/$id' : repoPath,
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
  test('flattens a multi-repo connection into one entry per repo', () async {
    final c = _container(
      conns: [
        _c(
          'conn',
          DateTime.utc(2026, 1, 1),
          repoPath: '/srv/alpha',
          repoPaths: ['/srv/alpha', '/srv/beta', '/srv/gamma'],
        ),
      ],
    );
    await _warm(c);

    final recent = c.read(recentReposProvider);
    // One row per known repo path; default repo (alpha) stays first.
    expect(recent.map((r) => r.repoName).toList(), ['alpha', 'beta', 'gamma']);
    // Every row is a remote repo carrying the same owning connection...
    expect(recent.every((r) => r is RecentRemoteRepo), isTrue);
    expect(
      recent.whereType<RecentRemoteRepo>().every((r) => r.connection.id == 'conn'),
      isTrue,
    );
    // ...but each with its own repoPath, and the connection name as location.
    expect(recent.map((r) => r.location).toSet(), {'conn'});
    expect(
      recent.whereType<RecentRemoteRepo>().map((r) => r.repoPath).toList(),
      ['/srv/alpha', '/srv/beta', '/srv/gamma'],
    );
  });

  test('remote and local repos interleave newest-first', () async {
    final c = _container(
      conns: [
        _c('old', DateTime.utc(2026, 1, 1), repoPath: '/srv/old'),
        _c('new', DateTime.utc(2026, 6, 1), repoPath: '/srv/new'),
      ],
      locals: [_l('localNewest', DateTime.utc(2026, 8, 1))],
    );
    await _warm(c);

    final recent = c.read(recentReposProvider);
    expect(recent.map((r) => r.repoName).toList(), ['localNewest', 'new', 'old']);
    expect(recent.first, isA<RecentLocalRepoEntry>());
  });

  test('local repo location is its containing folder', () async {
    final c = _container(
      locals: [
        _l('proj', DateTime.utc(2026, 2, 1), repoPath: '/Users/me/code/proj'),
      ],
    );
    await _warm(c);

    final recent = c.read(recentReposProvider);
    expect(recent.single.repoName, 'proj');
    expect(recent.single.location, '/Users/me/code');
  });

  test('caps the list at five entries total', () async {
    final c = _container(
      conns: [
        _c(
          'conn',
          DateTime.utc(2026, 1, 1),
          repoPath: '/srv/r0',
          repoPaths: [for (var i = 0; i < 12; i++) '/srv/r$i'],
        ),
      ],
    );
    await _warm(c);
    expect(c.read(recentReposProvider), hasLength(5));
  });

  test('is empty when nothing is saved', () async {
    final c = _container();
    await _warm(c);
    expect(c.read(recentReposProvider), isEmpty);
  });
}
