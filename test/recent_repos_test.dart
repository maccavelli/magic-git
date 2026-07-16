// recentReposProvider: the repo-centric landing list. The per-repo MRU
// (recentRepoRefsProvider) is the ONLY ranking source — exactly the workspaces
// most recently opened, local or remote, never connections standing in for
// them. A one-repo-per-connection fallback exists solely to bootstrap an EMPTY
// MRU (fresh install); it never pads a non-empty one. An MRU entry survives as
// long as its owning profile exists — profile-membership of the path is NOT
// required (the in-session switcher records opens it never persists).

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/storage/recent_repos_store.dart';
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

RecentRepoRef _remote(String connId, String repoPath, DateTime at) =>
    RecentRepoRef(isLocal: false, id: connId, repoPath: repoPath, openedAt: at);

RecentRepoRef _local(String localId, DateTime at) => RecentRepoRef(
  isLocal: true,
  id: localId,
  repoPath: '/Users/me/code/$localId',
  openedAt: at,
);

ProviderContainer _container({
  List<SavedConnection> conns = const [],
  List<SavedLocalRepo> locals = const [],
  List<RecentRepoRef> mru = const [],
}) {
  final c = ProviderContainer(
    overrides: [
      savedConnectionsProvider.overrideWith((ref) => conns),
      savedLocalReposProvider.overrideWith((ref) => locals),
      recentRepoRefsProvider.overrideWith((ref) => mru),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

Future<void> _warm(ProviderContainer c) async {
  await c.read(savedConnectionsProvider.future);
  await c.read(savedLocalReposProvider.future);
  await c.read(recentRepoRefsProvider.future);
}

void main() {
  test(
    'a multi-repo connection contributes ONE entry, so a local repo is not '
    'buried (the reported bug)',
    () async {
      final c = _container(
        conns: [
          _c(
            'host',
            DateTime.utc(2026, 1, 1),
            repoPath: '/a',
            repoPaths: ['/a', '/b', '/c', '/d', '/e'],
          ),
        ],
        locals: [_l('magic-git', DateTime.utc(2026, 6, 1))],
        // No MRU yet -> pure fallback (e.g. first run after the fix shipped).
      );
      await _warm(c);

      final recent = c.read(recentReposProvider);
      // The local repo (used more recently) leads; the connection adds only its
      // default repo — NOT all five, which used to crowd the local one out.
      expect(recent.map((r) => r.repoName).toList(), ['magic-git', 'a']);
      expect(recent.whereType<RecentLocalRepoEntry>(), hasLength(1));
    },
  );

  test('the MRU ranks the specific repo opened, ahead of the fallback', () async {
    final c = _container(
      conns: [
        _c('host', DateTime.utc(2026, 1, 1), repoPath: '/a', repoPaths: ['/a', '/b']),
      ],
      // The user actually opened /b (not the default /a).
      mru: [_remote('host', '/b', DateTime.utc(2026, 5, 1))],
    );
    await _warm(c);

    final recent = c.read(recentReposProvider);
    // Exactly the opened repo shows; the connection does not also re-add its
    // default, so one host can't reclaim a slot its unopened repo never earned.
    expect(recent, hasLength(1));
    final only = recent.single as RecentRemoteRepo;
    expect(only.repoPath, '/b');
  });

  test('MRU order interleaves local and remote by open time', () async {
    final c = _container(
      conns: [_c('host', DateTime.utc(2026, 1, 1), repoPath: '/a')],
      locals: [_l('magic-git', DateTime.utc(2026, 1, 1))],
      mru: [
        _local('magic-git', DateTime.utc(2026, 8, 1)), // newest
        _remote('host', '/a', DateTime.utc(2026, 7, 1)),
      ],
    );
    await _warm(c);

    expect(c.read(recentReposProvider).map((r) => r.repoName).toList(), [
      'magic-git',
      'a',
    ]);
  });

  test('an MRU entry for a deleted profile is dropped and the list self-heals', () async {
    final c = _container(
      conns: const [], // the 'gone' connection was deleted
      locals: [_l('magic-git', DateTime.utc(2026, 6, 1))],
      mru: [
        _remote('gone', '/x', DateTime.utc(2026, 9, 1)),
        _local('magic-git', DateTime.utc(2026, 6, 1)),
      ],
    );
    await _warm(c);

    // The dangling remote entry vanishes; the resolvable local one remains.
    expect(c.read(recentReposProvider).map((r) => r.repoName).toList(), [
      'magic-git',
    ]);
  });

  test(
    'an MRU repo not saved in the connection profile still shows '
    '(the switcher records opens it never persists — the reported regression)',
    () async {
      // setRepoPath records the open but deliberately does not rewrite the
      // saved profile, so requiring profile membership silently dropped every
      // repo opened via the in-session switcher — the landing list then showed
      // the CONNECTION default instead of the workspaces actually used.
      final c = _container(
        conns: [_c('host', DateTime.utc(2026, 1, 1), repoPath: '/a')],
        mru: [_remote('host', '/switched-to', DateTime.utc(2026, 9, 1))],
      );
      await _warm(c);

      final recent = c.read(recentReposProvider);
      expect((recent.single as RecentRemoteRepo).repoPath, '/switched-to');
    },
  );

  test('a non-empty MRU is never padded with connection stand-ins', () async {
    // One genuinely recent workspace + two other saved connections: the list
    // is ONLY the opened workspace — the fallback is bootstrap-only and must
    // not fill remaining slots with connections the user hasn't touched.
    final c = _container(
      conns: [
        _c('host', DateTime.utc(2026, 1, 1), repoPath: '/a'),
        _c('other1', DateTime.utc(2026, 6, 1)),
        _c('other2', DateTime.utc(2026, 6, 2)),
      ],
      locals: [_l('magic-git', DateTime.utc(2026, 6, 3))],
      mru: [_remote('host', '/a', DateTime.utc(2026, 9, 1))],
    );
    await _warm(c);

    final recent = c.read(recentReposProvider);
    expect(recent, hasLength(1));
    expect((recent.single as RecentRemoteRepo).repoPath, '/a');
  });

  test('caps the list at five entries total', () async {
    final c = _container(
      conns: [for (var i = 0; i < 8; i++) _c('c$i', DateTime.utc(2026, 1, i + 1))],
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
