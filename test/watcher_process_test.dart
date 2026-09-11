// MADR 0045 phase 3. The watcher process on the host — its channel, the race
// that settles an arm, and the refusals it decodes — as a unit of its own.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/bounded_watch.dart';
import 'package:remote_magic_git/core/git/remote_watch_service.dart';
import 'package:remote_magic_git/core/git/watch/source/remote/watcher_process.dart';
import 'package:remote_magic_git/core/git/watch/watch_timings.dart';
import 'package:remote_magic_git/core/git/watch_lifecycle.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

import 'helpers/fake_watcher_handle.dart';

/// Hands out [handle], or refuses a channel.
class _Channel extends SSHCommandExecutor {
  _Channel({this.handle, this.budgetSpent = false}) : super(SSHClientManager());

  final FakeWatcherHandle? handle;
  final bool budgetSpent;

  @override
  Future<SSHStreamHandle> executeStream({
    required String repoPath,
    required List<String> gitArgs,
    Map<String, String>? extraEnv,
    Duration openTimeout = SSHCommandExecutor.defaultTimeout,
    OperationDescriptor? operation,
    OperationEventCallback? onOperationEvent,
  }) async {
    if (budgetSpent) throw const SSHStreamBudgetExhausted('watch', 8, 8);
    return handle!;
  }
}

Future<WatcherOpen> _open(_Channel channel, {BoundedWatchSpec? spec}) =>
    WatcherProcess.open(
      executor: channel,
      repoPath: '/repo',
      args: const ['sh', '-c', 'watch'],
      tool: RemoteWatcherTool.inotifywait,
      spec: spec,
      timings: WatchTimings.standard,
      isCancelled: () => false,
      onActivity: () {},
      onPath: (_) {},
      onDied: (_) {},
    );

BoundedWatchSpec _spec() => computeBoundedWatchSpec(
  gitDir: '/repo/.git',
  workTree: '/repo',
  trackedFiles: const ['a.txt'],
);

void main() {
  test('the marker settles the arm', () async {
    final watch = Stopwatch()..start();
    final opened = await _open(_Channel(handle: FakeWatcherHandle.armed()));

    expect(opened, isA<WatcherOpened>());
    expect(
      watch.elapsed,
      lessThan(WatchTimings.standard.armSignalCeiling),
      reason: 'a healthy arm settles on its marker, not on the ceiling',
    );
    await (opened as WatcherOpened).process.close();
  });

  test('98 is heldByAnother and names the incumbent', () async {
    final opened = await _open(
      _Channel(
        handle: FakeWatcherHandle.refused(
          boundedWatchLockedExit,
          stderrLine: 'mg-watch: lock held by incumbent-token',
        ),
      ),
    );

    expect(opened, isA<WatcherRefused>());
    final refused = opened as WatcherRefused;
    expect(refused.reason, WatchUnavailableReason.heldByAnother);
    await refused.discard();
    expect(
      refused.incumbent(),
      'incumbent-token',
      reason:
          'read when asked, so a line arriving just after the status is kept',
    );
  });

  test('97 on a bounded surface is noWatchedPaths', () async {
    final opened = await _open(
      _Channel(handle: FakeWatcherHandle.refused(boundedWatchNoPathsExit)),
      spec: _spec(),
    );

    expect(opened, isA<WatcherRefused>());
    expect(
      (opened as WatcherRefused).reason,
      WatchUnavailableReason.noWatchedPaths,
    );
    await opened.discard();
  });

  test('97 on a recursive surface is not a refusal', () async {
    final opened = await _open(
      _Channel(handle: FakeWatcherHandle.refused(boundedWatchNoPathsExit)),
    );

    expect(
      opened,
      isA<WatcherOpened>(),
      reason:
          '97 means "the bounded spec matched no paths", which a recursive arm '
          'cannot produce, so it is not read as one there',
    );
    await (opened as WatcherOpened).process.close();
  });

  test('stream-budget exhaustion is unavailable, not thrown', () async {
    final opened = await _open(_Channel(budgetSpent: true));

    expect(
      opened,
      isA<WatcherBudgetSpent>(),
      reason:
          'deterministic, not a blip: retrying just hits the same wall and '
          'spends the restart budget doing it (0024 M2)',
    );
  });
}
