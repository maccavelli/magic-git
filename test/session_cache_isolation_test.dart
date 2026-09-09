// MADR 0039 F1/F2 — the eleven diff/blame/log caches in `app_providers.dart`
// are ONE set of objects for the process, but every tab is its own root
// ProviderContainer with its own KeepAliveLinks. These tests drive two
// containers against the same LRU keys and assert neither can reach the other's
// entries.
//
// Two containers on the same repoPath is not a contrived setup: tabs dedupe on
// (connectionId, repoPath, savedKind), so two SAVED CONNECTIONS that resolve
// the same path — two entries for one server, or two hosts that both mount a
// repo at the same conventional path — are two tabs with identical cache keys.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/providers/session_scope.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

import 'helpers/app_scope.dart';

const _repo = '/srv/repo';
const _hash = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _key = (_repo, _hash, 3);

class _CountingGit extends GitService {
  _CountingGit({this.fail = false, this.patch = 'diff --git a/x b/x\n'})
    : super(SSHCommandExecutor(SSHClientManager()));

  final bool fail;
  final String patch;
  int shows = 0;

  @override
  Future<String> showCommit(
    String repoPath,
    String hash, {
    int? context,
    String? path,
  }) async {
    shows++;
    if (fail) throw StateError('transport blip');
    return patch;
  }
}

ProviderContainer _session(SessionScope scope, GitService git) {
  final container = appProviderContainer(
    overrides: [
      sessionScopeProvider.overrideWithValue(scope),
      gitServiceProvider.overrideWithValue(git),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// Reads [commitDiffProvider] and then stops watching it. What keeps the
/// element alive from here on is the LRU's link and nothing else — which is
/// exactly the state these tests are about.
Future<ProviderSubscription<AsyncValue<String>>> _openThenLookAway(
  ProviderContainer container,
) async {
  final sub = container.listen(commitDiffProvider(_key), (_, _) {});
  await container.read(commitDiffProvider(_key).future);
  sub.close();
  return sub;
}

void main() {
  const scopeA = SessionScope(101);
  const scopeB = SessionScope(102);

  test('two sessions each keep their own entry for the same key', () async {
    final gitA = _CountingGit();
    final gitB = _CountingGit();
    final a = _session(scopeA, gitA);
    final b = _session(scopeB, gitB);

    await _openThenLookAway(a);
    await _openThenLookAway(b);

    // Both are unwatched now and held up only by the LRU. If B's touch had
    // dropped A's link (the unscoped behaviour), A's element would still be
    // pinned — but by nothing the LRU can see or ever release.
    expect(gitA.shows, 1);
    expect(gitB.shows, 1);
    expect(a.read(commitDiffProvider(_key)).value, isNotNull);
    expect(b.read(commitDiffProvider(_key)).value, isNotNull);
    expect(gitA.shows, 1, reason: 'served from A\'s own retained entry');
    expect(gitB.shows, 1, reason: 'served from B\'s own retained entry');
  });

  test(
    'a connect in one session does not drop the other session\'s cache',
    () async {
      // F1, the whole finding: _invalidateRepoState runs in ONE container and
      // used to clear the LRUs for every container in the process — on every
      // connect attempt, including each retry of an auto-reconnect.
      final gitA = _CountingGit();
      final gitB = _CountingGit();
      final a = _session(scopeA, gitA);
      final b = _session(scopeB, gitB);

      await _openThenLookAway(a);
      await _openThenLookAway(b);
      expect(gitA.shows, 1);
      expect(gitB.shows, 1);

      clearHashKeyedRepoCaches(scopeB);
      // Closing a KeepAliveLink only makes the element disposable; Riverpod
      // runs the disposal itself on a later turn.
      await pumpEventQueue();

      // B released its entry, so B refetches.
      expect(b.read(commitDiffProvider(_key)).value, isNull);
      await b.read(commitDiffProvider(_key).future);
      expect(gitB.shows, 2);

      // A never asked for anything and must be untouched.
      expect(
        a.read(commitDiffProvider(_key)).value,
        isNotNull,
        reason: 'session B\'s connect must not release session A\'s entries',
      );
      expect(gitA.shows, 1);
    },
  );

  test('a failed fetch releases only the failing session\'s entry', () async {
    // F2's evict half: the error path calls `evict(key)` so a transient blip
    // does not pin an AsyncError forever. Unscoped, session A's FAILURE closed
    // session B's SUCCESSFUL entry.
    final gitA = _CountingGit(fail: true);
    final gitB = _CountingGit();
    final a = _session(scopeA, gitA);
    final b = _session(scopeB, gitB);

    await _openThenLookAway(b);
    expect(gitB.shows, 1);

    final sub = a.listen(commitDiffProvider(_key), (_, _) {});
    await expectLater(
      a.read(commitDiffProvider(_key).future),
      throwsA(isA<StateError>()),
    );
    sub.close();

    expect(
      b.read(commitDiffProvider(_key)).value,
      isNotNull,
      reason: 'one session\'s failed fetch must not evict another\'s result',
    );
    expect(gitB.shows, 1);
  });

  test(
    'an oversized payload in one session does not evict the other',
    () async {
      // F2's reportSize half. The immutable tier's per-entry cap is 16 MiB;
      // charge one session a payload over it and the other must be untouched.
      final huge = 'x' * (17 * 1024 * 1024);
      final gitA = _CountingGit(patch: huge);
      final gitB = _CountingGit();
      final a = _session(scopeA, gitA);
      final b = _session(scopeB, gitB);

      await _openThenLookAway(b);
      await _openThenLookAway(a);

      expect(
        b.read(commitDiffProvider(_key)).value,
        isNotNull,
        reason:
            'A\'s payload size was charged against whichever session '
            'happened to hold the unscoped key',
      );
      expect(gitB.shows, 1);
    },
  );
}
