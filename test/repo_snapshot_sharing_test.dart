// One refresh wave must cost one snapshot command.
//
// 0025 Finding B, attributed: instrumenting the refresh triggers during a real
// commit+push showed only SIX of them across 41 seconds — yet the host ran
// FIFTEEN snapshot commands. The multiplication is in the provider layer.
// `statusProvider`, `refsProvider` and `pendingOpProvider` each ask GitService
// for a snapshot independently, and `_snapshotInFlight` dedupes only strictly
// concurrent callers — but Riverpod rebuilds the three as their listeners
// settle, not in one instant. So each wave issued two or three identical
// commands.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/utils/git_porcelain_parser.dart';

import 'helpers/app_scope.dart';

/// Counts how many times the provider layer asks for a snapshot. Overriding
/// the public accessor bypasses GitService's own in-flight dedup on purpose:
/// what is under test is whether the PROVIDERS share one fetch.
class _CountingGit extends GitService {
  _CountingGit() : super(SSHCommandExecutor(SSHClientManager()));

  int snapshotCalls = 0;

  @override
  Future<RepoSnapshot> snapshot(String repoPath) async {
    snapshotCalls++;
    return RepoSnapshot(
      status: GitStatus(branch: const GitBranchInfo(), files: const []),
      refs: const [],
      pendingOp: PendingOp.none,
      remotes: const ['origin'],
    );
  }
}

void main() {
  test('three snapshot-backed providers share one fetch', () async {
    final git = _CountingGit();
    final container = appProviderContainer(
      overrides: [gitServiceProvider.overrideWithValue(git)],
    );
    addTearDown(container.dispose);

    // Sequentially, the way Riverpod actually rebuilds listeners. Reading them
    // concurrently would be deduped by `_snapshotInFlight` and prove nothing.
    await container.read(statusProvider('/r').future);
    await container.read(refsProvider('/r').future);
    await container.read(pendingOpProvider('/r').future);

    expect(
      git.snapshotCalls,
      1,
      reason: 'one wave, one command — not one per derived provider',
    );
  });

  test('a refresh wave re-fetches exactly once', () async {
    final git = _CountingGit();
    final container = appProviderContainer(
      overrides: [gitServiceProvider.overrideWithValue(git)],
    );
    addTearDown(container.dispose);

    await container.read(statusProvider('/r').future);
    expect(git.snapshotCalls, 1);

    container.invalidate(repoSnapshotProvider('/r'));
    await container.read(statusProvider('/r').future);
    await container.read(refsProvider('/r').future);
    await container.read(pendingOpProvider('/r').future);

    expect(git.snapshotCalls, 2, reason: 'the wave costs one more, not three');
  });

  test('no feature invalidates a derived view instead of the fetch', () {
    // Invalidating statusProvider alone re-derives it from the CACHED
    // snapshot — a silent no-op that looks like a refresh. The fetch is
    // repoSnapshotProvider, and this is the same one-definition rule the
    // mutation set already enforces.
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.path.endsWith('app_providers.dart')) continue;
      final source = entity.readAsStringSync();
      for (final view in const [
        'statusProvider',
        'refsProvider',
        'pendingOpProvider',
      ]) {
        if (source.contains('invalidate($view(')) {
          offenders.add('${entity.path}: invalidate($view(…))');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'invalidate repoSnapshotProvider(repoPath) instead:\n'
          '${offenders.join('\n')}',
    );
  });
}
