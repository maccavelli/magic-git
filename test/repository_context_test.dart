import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/features/common/repository_context.dart';

RepositoryContextSnapshot _snapshot({
  bool pending = false,
  int conflicts = 0,
  int ahead = 0,
  int behind = 0,
  bool upstream = false,
  bool remote = false,
  bool connected = true,
  bool busy = false,
  bool incomplete = false,
}) => RepositoryContextSnapshot(
  repositoryPath: '/repo',
  repositoryName: 'repo',
  branchLabel: 'main',
  hasPendingOperation: pending,
  conflictCount: conflicts,
  ahead: ahead,
  behind: behind,
  hasUpstream: upstream,
  hasConfiguredRemote: remote,
  connected: connected,
  busy: busy,
  incomplete: incomplete,
);

void main() {
  final cases =
      <
        ({
          RepositoryContextSnapshot state,
          RepositoryPrimaryActionKind expected,
        })
      >[
        (
          state: _snapshot(pending: true, conflicts: 2),
          expected: RepositoryPrimaryActionKind.resolve,
        ),
        (
          state: _snapshot(pending: true),
          expected: RepositoryPrimaryActionKind.continueOperation,
        ),
        (
          state: _snapshot(conflicts: 1),
          expected: RepositoryPrimaryActionKind.resolve,
        ),
        (
          state: _snapshot(ahead: 2, behind: 1, upstream: true),
          expected: RepositoryPrimaryActionKind.sync,
        ),
        (
          state: _snapshot(behind: 1, upstream: true),
          expected: RepositoryPrimaryActionKind.pull,
        ),
        (
          state: _snapshot(ahead: 1, upstream: true),
          expected: RepositoryPrimaryActionKind.push,
        ),
        (
          state: _snapshot(remote: true),
          expected: RepositoryPrimaryActionKind.publish,
        ),
        (state: _snapshot(), expected: RepositoryPrimaryActionKind.fetch),
      ];

  for (final entry in cases) {
    test('primary precedence resolves ${entry.expected.name}', () {
      expect(resolvePrimaryRepositoryAction(entry.state).kind, entry.expected);
    });
  }

  test('disabled reasons do not alter the resolved action', () {
    final disconnected = resolvePrimaryRepositoryAction(
      _snapshot(ahead: 1, upstream: true, connected: false),
    );
    final incomplete = resolvePrimaryRepositoryAction(
      _snapshot(behind: 1, incomplete: true),
    );
    final busy = resolvePrimaryRepositoryAction(_snapshot(busy: true));

    expect(disconnected.kind, RepositoryPrimaryActionKind.push);
    expect(disconnected.disabledReason, 'Repository is disconnected');
    expect(incomplete.kind, RepositoryPrimaryActionKind.pull);
    expect(incomplete.disabledReason, 'Repository context is still loading');
    expect(busy.disabledReason, 'Another repository operation is running');
  });

  test('supplement cache merges landed values and isolates session epochs', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    const first = RepositoryContextSupplementKey(
      repositoryIdentity: 'repo-a',
      sessionEpoch: 1,
    );
    const second = RepositoryContextSupplementKey(
      repositoryIdentity: 'repo-a',
      sessionEpoch: 2,
    );
    final notifier = container.read(
      repositoryContextSupplementCacheProvider.notifier,
    );
    notifier
      ..publish(
        first,
        const RepositoryContextSupplement(worktreeLabel: 'main worktree'),
      )
      ..publish(first, const RepositoryContextSupplement(forgeLabel: 'PR #42'))
      ..publish(
        second,
        const RepositoryContextSupplement(worktreeLabel: 'new session'),
      );

    final cache = container.read(repositoryContextSupplementCacheProvider);
    expect(cache[first]?.worktreeLabel, 'main worktree');
    expect(cache[first]?.forgeLabel, 'PR #42');
    expect(cache[second]?.worktreeLabel, 'new session');

    notifier.clearSession(1);
    expect(
      container.read(repositoryContextSupplementCacheProvider)[first],
      isNull,
    );
    expect(
      container.read(repositoryContextSupplementCacheProvider)[second],
      isNotNull,
    );
  });
}
